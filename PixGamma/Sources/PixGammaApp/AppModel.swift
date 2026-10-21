import AppKit
import Foundation
import PixGammaCore
import SwiftUI

enum SizeMode: String, CaseIterable, Identifiable {
    case factor, width, height
    var id: String { rawValue }
}

final class ImageItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var thumbnail: NSImage?
    /// Screen-sized rendition of the source for the canvas.
    @Published var display: NSImage?
    @Published var source: LoadedImage?
    @Published var previewBefore: NSImage?
    @Published var previewAfter: NSImage?
    @Published var report: UpscaleReport?
    @Published var analysis: ImageAnalysis?
    @Published var status: String = "Chờ"
    @Published var exportedURL: URL?

    init(url: URL) { self.url = url }

    var pixelSize: (Int, Int)? { source.map { ($0.image.width, $0.image.height) } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ImageItem] = []
    @Published var selection: ImageItem.ID?

    // Settings (strengths are 0–100 in the UI)
    @Published var mode: EnhanceMode = .auto
    @Published var sizeMode: SizeMode = .factor
    @Published var factor: Double = 4
    @Published var targetWidth: Int = 3840
    @Published var targetHeight: Int = 2160
    @Published var autoStrengths = true
    @Published var denoise: Double = 50
    @Published var sharpen: Double = 0
    @Published var compression: Double = 0
    @Published var detail: Double = 35
    @Published var creativity: Double = 75
    @Published var resemblance: Double = 40
    @Published var texture: Double = 25
    @Published var contrast: Double = 30
    @Published var protectText = true
    @Published var faceEnabled = true
    @Published var face: Double = 70
    @Published var faceStyle: FaceStyle = .realistic
    @Published var faceFidelity: Double = 70
    @Published var preserveColor = true
    @Published var device: ComputeDevice = .gpu

    // Export
    @Published var format: OutputFormat = .preserve
    @Published var jpegQuality: Double = 95
    @Published var outputFolder: URL?
    @Published var suffix = "-pixgamma"

    // View state
    @Published var showTuning = true
    @Published var compareStyle: CompareStyle = .split
    @Published var zoom: ZoomLevel = .fit

    @Published var busy = false
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var apiRunning = false
    private var api: APIServer?
    private var cancelToken = CancelToken()

    var selected: ImageItem? { items.first { $0.id == selection } }

    // MARK: Items

    func add(urls: [URL]) {
        let files = Batch.collect(urls, recursive: true).map(\.url)
        for url in files where !items.contains(where: { $0.url == url }) {
            let item = ImageItem(url: url)
            items.append(item)
            Task.detached(priority: .userInitiated) {
                let loaded = try? ImageFile.load(url)
                func rendition(_ l: LoadedImage, _ maxSide: Double) -> NSImage? {
                    let s = min(1, maxSide / Double(max(l.image.width, l.image.height)))
                    let t = l.image.resized(width: max(1, Int(Double(l.image.width) * s)), height: max(1, Int(Double(l.image.height) * s)))
                    return t.makeCGImage().map { NSImage(cgImage: $0, size: .zero) }
                }
                let thumb = loaded.flatMap { rendition($0, 160) }
                let display = loaded.flatMap { rendition($0, 2400) }
                let analysis = loaded.map { Analyzer.analyze($0.image, faceCount: FaceRestorer.detect($0.image).count) }
                await MainActor.run {
                    item.source = loaded
                    item.thumbnail = thumb
                    item.display = display
                    item.analysis = analysis
                    item.status = loaded == nil ? "Lỗi đọc ảnh" : "Sẵn sàng"
                }
            }
        }
        if selection == nil { selection = items.first?.id }
    }

    func remove(_ item: ImageItem) {
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = items.first?.id }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    // MARK: Options

    var outputSize: OutputSize {
        switch sizeMode {
        case .factor: return .factor(factor)
        case .width: return .width(targetWidth)
        case .height: return .height(targetHeight)
        }
    }

    func options() -> UpscaleOptions {
        var o = UpscaleOptions()
        o.mode = mode
        o.size = outputSize
        if !(mode == .auto && autoStrengths) {
            o.denoise = denoise / 100
            o.sharpen = sharpen / 100
            o.compression = compression / 100
            o.detail = detail / 100
            o.texture = texture / 100
            o.contrast = contrast / 100
        }
        o.creativity = creativity / 100
        o.resemblance = resemblance / 100
        o.protectText = protectText
        o.faceStyle = faceStyle
        o.faceFidelity = faceFidelity / 100
        o.faceRecovery = faceEnabled ? face / 100 : 0
        if mode == .auto && autoStrengths && faceEnabled { o.faceRecovery = nil }
        o.preserveColor = preserveColor
        o.device = device
        return o
    }

    func outputDimensions(for item: ImageItem) -> String {
        guard let (w, h) = item.pixelSize else { return "—" }
        let (ow, oh) = outputSize.resolve(width: w, height: h)
        return "\(w)×\(h) → \(ow)×\(oh)"
    }

    // MARK: Processing

    /// Quick preview: process a crop around the centre so settings can be tried quickly.
    func preview() {
        guard let item = selected, let src = item.source?.image, !busy else { return }
        let opts = options()
        let crop = min(320, src.width, src.height)
        let region = src.cropped(x: (src.width - crop) / 2, y: (src.height - crop) / 2, width: crop, height: crop)
        let (fullW, _) = opts.size.resolve(width: src.width, height: src.height)
        var o = opts
        o.size = .factor(Double(fullW) / Double(src.width))
        let cropOpts = o
        let progress = progressHandler()
        run(label: "Xem trước") {
            let result = try Upscaler.upscale(region, options: cropOpts, progress: progress)
            let before = region.resized(width: result.image.width, height: result.image.height)
            await MainActor.run {
                item.previewBefore = before.makeCGImage().map { NSImage(cgImage: $0, size: .zero) }
                item.previewAfter = result.image.makeCGImage().map { NSImage(cgImage: $0, size: .zero) }
                item.report = result.report
            }
        }
    }

    func exportAll() { export(items) }
    func exportSelected() { if let s = selected { export([s]) } }

    private func export(_ list: [ImageItem]) {
        guard !busy, !list.isEmpty else { return }
        let opts = options()
        let settings = ExportSettings(format: format, jpegQuality: jpegQuality / 100)
        let naming = NamingOptions(suffix: suffix)
        let folder = outputFolder
        let format = format
        let progress = progressHandler()
        run(label: "Xuất ảnh") {
            for (i, item) in list.enumerated() {
                await MainActor.run { item.status = "Đang xử lý…"; self.stage = "\(i + 1)/\(list.count) \(item.url.lastPathComponent)" }
                let dest = Batch.outputURL(for: item.url, relative: item.url.lastPathComponent, outputDirectory: folder,
                                           format: format, naming: naming, modeName: opts.mode.rawValue,
                                           sizeTag: Batch.sizeTag(opts.size))
                do {
                    guard let loaded = item.source else { throw PixGammaError.imageDecode(item.url.path) }
                    let result = try Upscaler.upscale(loaded.image, options: opts, progress: progress)
                    try ImageFile.save(result.image, to: dest, settings: settings, sourceProperties: loaded.properties,
                                       sourceExtension: item.url.pathExtension)
                    await MainActor.run { item.report = result.report }
                    await MainActor.run { item.status = "Đã xuất"; item.exportedURL = dest }
                } catch is CancellationError {
                    await MainActor.run { item.status = "Đã huỷ" }
                    throw CancellationError()
                } catch {
                    await MainActor.run { item.status = "Lỗi: \(error.localizedDescription)" }
                }
            }
        }
    }

    func cancel() { cancelToken.cancel() }

    private func progressHandler() -> ProgressHandler {
        let token = cancelToken
        return { [weak self] stage, f in
            Task { @MainActor in self?.stage = stage; self?.progress = f }
            return !token.isCancelled
        }
    }

    private func run(label: String, _ work: @escaping @Sendable () async throws -> Void) {
        busy = true; progress = 0; stage = label
        cancelToken = CancelToken()
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try await work() } catch {
                failure = error is CancellationError ? "Đã huỷ" : error.localizedDescription
            }
            let message = failure
            await MainActor.run {
                self.busy = false
                self.stage = message ?? "Xong"
            }
        }
    }

    // MARK: API

    func toggleAPI() {
        if let api {
            api.stop(); self.api = nil; apiRunning = false
        } else {
            let server = APIServer(log: { _ in })
            do { try server.start(); api = server; apiRunning = true } catch { stage = "API: \(error.localizedDescription)" }
        }
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
