import AppKit
import PixGammaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PixGammaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()
    @AppStorage("appearance") private var appearance: AppearanceChoice = .system

    var body: some Scene {
        WindowGroup("PixGamma") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .sheet(isPresented: $updates.showing) { UpdateSheet().environmentObject(updates) }
                .onAppear {
                    NSApp.appearance = appearance.nsAppearance
                    updates.checkOnLaunch()
                }
                .onChange(of: appearance) { _, new in NSApp.appearance = new.nsAppearance }
                .frame(minWidth: 1180, minHeight: 740)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Kiểm tra cập nhật…") { updates.checkNow() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Mở ảnh…") { model.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Picker("Giao diện", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                }
                Button(model.showTuning ? "Ẩn tinh chỉnh" : "Hiện tinh chỉnh") { model.showTuning.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Picker("Thu phóng", selection: $model.zoom) {
                    ForEach(ZoomLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
            }
            CommandMenu("Xử lý") {
                Button("Xem trước") { model.preview() }.keyboardShortcut("p")
                Button("Xuất ảnh đang chọn") { model.exportSelected() }.keyboardShortcut("e")
                Button("Xuất tất cả") { model.exportAll() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button(model.apiRunning ? "Tắt API cục bộ" : "Bật API cục bộ (cổng 8765)") { model.toggleAPI() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum ZoomLevel: String, CaseIterable, Identifiable {
    case fit = "Vừa", actual = "100%", double = "200%"
    var id: String { rawValue }
    var scale: CGFloat { self == .double ? 2 : 1 }
}

enum CompareStyle: String, CaseIterable, Identifiable {
    case split, sideBySide
    var id: String { rawValue }
}

extension EnhanceMode {
    /// Short label for the dock.
    var shortName: String {
        switch self {
        case .auto: return "Auto"
        case .standard: return "Ảnh chụp"
        case .fidelity: return "Chân thực"
        case .art: return "Tranh vẽ"
        case .lowres: return "Ảnh nhỏ"
        case .recover: return "Recover"
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .standard: return "photo"
        case .fidelity: return "scope"
        case .art: return "paintpalette"
        case .lowres: return "square.grid.2x2"
        case .recover: return "sparkles"
        }
    }
}

extension NSImage {
    var pixelSize: CGSize {
        representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? size
    }
}

/// "12,5" — one decimal with a Vietnamese comma.
func viDecimal(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

/// Room the photo leaves for the chips above it and the dock below it.
private let stageTopInset: CGFloat = 56
private let stageBottomInset: CGFloat = 96

// MARK: - Root

/// Canvas-first layout: top bar, the photo on a rounded stage with a small dock floating on its
/// bottom edge, the filmstrip under it, and the tuning column on the right (collapsible).
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar().frame(height: 52)
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Stage(dropTargeted: dropTargeted)
                        .overlay(alignment: .bottom) { Dock().padding(.bottom, 16).padding(.horizontal, 16) }
                    Filmstrip().frame(height: 104)
                }
                if model.showTuning {
                    TuningColumn()
                        .frame(width: 320)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.showTuning)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add(urls: [url]) } }
                }
            }
            return true
        }
        .onOpenURL { model.add(urls: [$0]) }
        .onAppear {
            // `PixGammaApp file1 file2…` preloads images (handy for testing and Finder scripts).
            let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if !paths.isEmpty { model.add(urls: paths.map { URL(fileURLWithPath: $0) }) }
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 70)       // traffic lights
            LogoMark(size: 22)
            Text("PixGamma").font(.system(size: 14, weight: .bold)).tracking(-0.2).fixedSize()
            if let item = model.selected {
                Rectangle().fill(Theme.line2).frame(width: 1, height: 22).padding(.horizontal, 4)
                FileTitle(item: item)
            }
            Spacer(minLength: 12)
            Segmented(selection: $model.compareStyle, options: [(.split, "Chia đôi", nil), (.sideBySide, "Song song", nil)])
                .help("Cách so sánh trước / sau khi soi ở 100% hoặc 200%")
            Segmented(selection: $model.zoom, options: ZoomLevel.allCases.map { ($0, $0.rawValue, nil) })
                .help("Vừa: xem cả ảnh. 100% / 200%: soi chi tiết vùng đã xem trước.")
            IconToggle(symbol: "sidebar.right", on: model.showTuning, help: "Tinh chỉnh (⌥⌘I)") { model.showTuning.toggle() }
            ExportButtons()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }
}

struct FileTitle: View {
    @ObservedObject var item: ImageItem
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.url.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(model.outputDimensions(for: item).replacingOccurrences(of: "×", with: " × "))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .layoutPriority(-1)
    }
}

/// Two explicit scopes: the photo on screen, or the whole list.
struct ExportButtons: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let many = model.items.count > 1
        HStack(spacing: 6) {
            if many {
                Button("Xuất ảnh này") { model.exportSelected() }
                    .buttonStyle(ActionButtonStyle(kind: .quiet, height: 32))
                    .disabled(model.selected == nil || model.busy)
                    .help("Chỉ xuất ảnh đang mở (⌘E)")
            }
            Button {
                many ? model.exportAll() : model.exportSelected()
            } label: {
                Label(many ? "Xuất tất cả (\(model.items.count))" : "Xuất ảnh", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(ActionButtonStyle(kind: .accent, height: 32))
            .disabled(model.items.isEmpty || model.busy)
            .help(many ? "Xuất toàn bộ \(model.items.count) ảnh trong danh sách với thiết lập hiện tại (⇧⌘E)"
                       : "Xuất ảnh với thiết lập hiện tại (⌘E)")
        }
        .fixedSize()
    }
}

// MARK: - Stage

struct Stage: View {
    @EnvironmentObject var model: AppModel
    let dropTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
        ZStack {
            Theme.stage
            if let item = model.selected {
                ItemStage(item: item)
            } else {
                EmptyStage()
            }
            if model.busy {
                VStack { ProgressLine(value: model.progress); Spacer() }
            }
            if dropTargeted {
                shape.strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(10)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.line))
    }
}

struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(Theme.accent).frame(width: g.size.width * max(0.02, min(1, value)), height: 3)
                .animation(.easeOut(duration: 0.2), value: value)
        }
        .frame(height: 3)
    }
}

struct EmptyStage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            LogoMark(size: 88).shadow(color: Theme.accent.opacity(0.3), radius: 30)
            VStack(spacing: 8) {
                Text("Thả ảnh vào đây").font(.system(size: 22, weight: .bold)).tracking(-0.3)
                Text("JPEG, PNG, HEIC, TIFF, WebP. Có thể thả cả thư mục.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Button { model.openPanel() } label: { Label("Chọn ảnh", systemImage: "plus") }
                .buttonStyle(ActionButtonStyle(kind: .accent, height: 36))
        }
        .padding(.bottom, 60)
    }
}

struct ItemStage: View {
    @ObservedObject var item: ImageItem
    @EnvironmentObject var model: AppModel
    @State private var split: CGFloat = 0.5

    var body: some View {
        let inspecting = model.zoom != .fit && item.previewAfter != nil
        ZStack {
            if let after = item.previewAfter, let before = item.previewBefore, model.zoom != .fit {
                if model.compareStyle == .split {
                    SplitCompare(before: before, after: after, split: $split, scale: model.zoom.scale)
                } else {
                    SideBySide(before: before, after: after, scale: model.zoom.scale, afterLabel: resultLabel)
                }
            } else if let display = item.display {
                if model.zoom == .fit {
                    FitImage(image: display, preview: item.previewAfter, region: previewRegion) { model.zoom = .actual }
                } else {
                    NativeImage(image: display, scale: model.zoom.scale)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            VStack {
                HStack(alignment: .top) {
                    if inspecting, model.compareStyle == .split { OverlayChip(text: "Ảnh gốc") }
                    Spacer()
                    StatsChips(item: item)
                    Spacer()
                    if inspecting, model.compareStyle == .split { OverlayChip(text: resultLabel) }
                }
                Spacer()
            }
            .padding(14)
        }
    }

    /// The centre crop that `AppModel.preview()` processes, as a fraction of the photo.
    private var previewRegion: CGRect? {
        guard let (w, h) = item.pixelSize, w > 0, h > 0 else { return nil }
        let c = min(320, w, h)
        return CGRect(x: Double((w - c) / 2) / Double(w), y: Double((h - c) / 2) / Double(h),
                      width: Double(c) / Double(w), height: Double(c) / Double(h))
    }

    private var resultLabel: String {
        switch model.sizeMode {
        case .factor: return "PixGamma \(model.factor.formatted(.number.precision(.fractionLength(0...2))))x"
        case .width: return "PixGamma \(model.targetWidth) px"
        case .height: return "PixGamma \(model.targetHeight) px"
        }
    }
}

struct StatsChips: View {
    @ObservedObject var item: ImageItem
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            if let r = item.report {
                OverlayChip(text: r.mode.displayName, bold: true)
                if r.textRegions > 0 { OverlayChip(text: "\(r.textRegions) vùng chữ") }
                if r.facesRestored > 0 { OverlayChip(text: "\(r.facesRestored) khuôn mặt") }
                OverlayChip(text: "\(viDecimal(r.seconds)) giây")
                if model.zoom == .fit { OverlayChip(text: "Chọn 100% để so sánh chi tiết") }
            } else if let a = item.analysis {
                OverlayChip(text: "Gợi ý: \(a.mode.displayName)", bold: true)
                OverlayChip(text: "Nhiễu \(viDecimal(a.noiseSigma))")
                if a.faceCount > 0 { OverlayChip(text: "\(a.faceCount) khuôn mặt") }
            }
        }
    }
}

/// Chip over the photo: always dark glass so it reads on any image, in either theme.
struct OverlayChip: View {
    let text: String
    var bold = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: bold ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
    }
}

/// Whole photo, fitted. After a preview the processed centre is drawn in place and outlined;
/// clicking it jumps to 100% to compare.
struct FitImage: View {
    let image: NSImage
    let preview: NSImage?
    let region: CGRect?
    let inspect: () -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let availW = g.size.width - 64, availH = g.size.height - stageTopInset - stageBottomInset
            let aspect = image.size.width / max(1, image.size.height)
            let w = max(1, min(availW, availH * aspect)), h = w / aspect
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: w, height: h)
                if let preview, let r = region {
                    Image(nsImage: preview).resizable().interpolation(.high)
                        .frame(width: w * r.width, height: h * r.height)
                        .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1.5))
                        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: hovering ? 3 : 2).padding(-2))
                        .shadow(color: .black.opacity(0.35), radius: 8)
                        .offset(x: w * r.minX, y: h * r.minY)
                        .onTapGesture(perform: inspect)
                        .onHover { hovering = $0 }
                        .help("Vùng đã xem trước. Bấm để soi ở 100%.")
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Theme.shadow, radius: 18, y: 8)
            .position(x: g.size.width / 2, y: stageTopInset + availH / 2)
        }
    }
}

/// Photo at real pixels (or doubled), scrollable.
struct NativeImage: View {
    let image: NSImage
    let scale: CGFloat
    var body: some View {
        GeometryReader { g in
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            let px = image.pixelSize
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().interpolation(scale > 1 ? .none : .high)
                    .frame(width: px.width * scale / backing, height: px.height * scale / backing)
                    .padding(.top, stageTopInset).padding(.bottom, stageBottomInset).padding(.horizontal, 32)
                    .frame(minWidth: g.size.width, minHeight: g.size.height)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.center)
        }
    }
}

/// Before/after at real pixels with a draggable divider; both layers share one frame so they line up.
struct SplitCompare: View {
    let before: NSImage
    let after: NSImage
    @Binding var split: CGFloat
    let scale: CGFloat

    var body: some View {
        GeometryReader { g in
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            let px = after.pixelSize
            let w = px.width * scale / backing, h = px.height * scale / backing
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .leading) {
                    Image(nsImage: before).resizable().interpolation(scale > 1 ? .none : .high)
                    Image(nsImage: after).resizable().interpolation(scale > 1 ? .none : .high)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: w * (1 - split)).offset(x: w * split)
                        }
                    Rectangle().fill(Color.white).frame(width: 2).shadow(color: .black.opacity(0.4), radius: 6)
                        .offset(x: w * split - 1)
                    CompareKnob().offset(x: w * split - 20)
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Theme.shadow, radius: 18, y: 8)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    split = min(1, max(0, v.location.x / w))
                })
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .padding(.top, stageTopInset).padding(.bottom, stageBottomInset).padding(.horizontal, 32)
                .frame(minWidth: g.size.width, minHeight: g.size.height)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.center)
        }
    }
}

struct CompareKnob: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            Circle().strokeBorder(Theme.accent, lineWidth: 2.5)
            Image(systemName: "chevron.left.chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
        }
        .frame(width: 40, height: 40)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

struct SideBySide: View {
    let before: NSImage
    let after: NSImage
    let scale: CGFloat
    let afterLabel: String

    var body: some View {
        GeometryReader { g in
            ScrollView([.horizontal, .vertical]) {
                HStack(spacing: 14) {
                    pane(before, "Ảnh gốc")
                    pane(after, afterLabel)
                }
                .padding(.top, stageTopInset).padding(.bottom, stageBottomInset).padding(.horizontal, 24)
                .frame(minWidth: g.size.width, minHeight: g.size.height)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.center)
        }
    }

    private func pane(_ image: NSImage, _ label: String) -> some View {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let px = after.pixelSize
        return Image(nsImage: image).resizable().interpolation(scale > 1 ? .none : .high)
            .frame(width: px.width * scale / backing, height: px.height * scale / backing)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) { OverlayChip(text: label).padding(10) }
            .shadow(color: Theme.shadow, radius: 14, y: 6)
    }
}

// MARK: - Dock

/// Only the three things you change per photo: mode, scale, and the preview action.
struct Dock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 10) {
            ModePicker(compact: compact)
            DockDivider()
            ScalePicker()
            DockDivider()
            RunButton()
        }
        .padding(8)
        .glassPanel()
        .fixedSize()
    }
}

struct DockDivider: View {
    var body: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 28) }
}

struct ModePicker: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool
    var body: some View {
        let modes = EnhanceMode.allCases.filter { $0 != .recover || GenerativeRefiner.isAvailable }
        HStack(spacing: 2) {
            ForEach(modes, id: \.self) { mode in
                PillButton(selected: model.mode == mode, help: "\(mode.displayName): \(mode.summary)") { model.mode = mode } label: {
                    if compact { Image(systemName: mode.symbol).frame(width: 16) } else { Label(mode.shortName, systemImage: mode.symbol) }
                }
            }
        }
        .padding(3)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ScalePicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach([2.0, 4, 6], id: \.self) { f in
                PillButton(selected: model.sizeMode == .factor && model.factor == f, help: "Phóng \(Int(f)) lần") {
                    model.sizeMode = .factor; model.factor = f
                } label: { Text("\(Int(f))x").monospacedDigit() }
            }
            Menu {
                ForEach([1.0, 3, 8, 12, 16], id: \.self) { f in
                    Button("\(Int(f))x") { model.sizeMode = .factor; model.factor = f }
                }
                Divider()
                Button("Tỉ lệ tuỳ chỉnh…") { model.sizeMode = .factor; model.showTuning = true }
                Button("Theo chiều rộng…") { model.sizeMode = .width; model.showTuning = true }
                Button("Theo chiều cao…") { model.sizeMode = .height; model.showTuning = true }
            } label: {
                Text(customLabel).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(isCustom ? Theme.accent : .clear))
            .foregroundStyle(isCustom ? Color.white : Theme.textSecondary)
            .help("Tỉ lệ khác, hoặc theo chiều rộng / chiều cao")
        }
        .padding(3)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var isCustom: Bool { model.sizeMode != .factor || ![2.0, 4, 6].contains(model.factor) }
    private var customLabel: String {
        guard isCustom else { return "···" }
        switch model.sizeMode {
        case .factor: return "\(model.factor.formatted(.number.precision(.fractionLength(0...2))))x"
        case .width: return "W \(model.targetWidth)"
        case .height: return "H \(model.targetHeight)"
        }
    }
}

struct RunButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.busy {
            HStack(spacing: 10) {
                ProgressView(value: model.progress).progressViewStyle(.circular).controlSize(.small)
                Text("\(Int(model.progress * 100))%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                Button("Huỷ") { model.cancel() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            Button { model.preview() } label: { Label("Xem trước", systemImage: "play.fill") }
                .buttonStyle(ActionButtonStyle(kind: .brand, height: 40))
                .disabled(model.selected == nil)
                .help("Chạy thiết lập hiện tại trên vùng giữa ảnh (⌘P)")
        }
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.items.isEmpty ? "Chưa có ảnh" : "\(model.items.count) ảnh").font(.system(size: 12, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).lineLimit(2)
                    .foregroundStyle(model.stage.hasPrefix("Lỗi") ? Theme.danger : Theme.textTertiary)
            }
            .frame(width: 150, alignment: .leading)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.items) { item in
                        Thumb(item: item, selected: model.selection == item.id)
                            .onTapGesture { model.selection = item.id }
                            .contextMenu {
                                Button("Xuất ảnh này") { model.selection = item.id; model.exportSelected() }
                                Button("Xoá khỏi danh sách") { model.remove(item) }
                                if let u = item.exportedURL {
                                    Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                }
                            }
                    }
                    AddThumb()
                }
                .padding(.horizontal, 4).padding(.vertical, 12)
            }
            .scrollIndicators(.never)

            APIPill()
        }
        .padding(.horizontal, 10)
    }

    private var statusLine: String {
        if model.busy { return model.stage }
        if !model.stage.isEmpty, model.stage != "Xong" { return model.stage }
        let previewed = model.items.filter { $0.previewAfter != nil }.count
        let exported = model.items.filter { $0.exportedURL != nil }.count
        if model.items.isEmpty { return "Thả ảnh hoặc bấm +" }
        return "\(previewed) đã xem trước · \(exported) đã xuất"
    }
}

struct Thumb: View {
    @ObservedObject var item: ImageItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            Theme.chip
            if let t = item.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
            if item.status == "Đang xử lý…" {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.line2, lineWidth: selected ? 2.5 : 1))
        .overlay(alignment: .bottomTrailing) { badge.padding(4) }
        .opacity(selected || hovering ? 1 : 0.8)
        .shadow(color: Theme.shadow.opacity(selected ? 1 : 0.5), radius: selected ? 10 : 5, y: 4)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help("\(item.url.lastPathComponent) · \(item.status)")
    }

    @ViewBuilder private var badge: some View {
        if item.status.hasPrefix("Lỗi") {
            BadgeDot(symbol: "exclamationmark", color: Theme.danger)
        } else if item.exportedURL != nil {
            BadgeDot(symbol: "checkmark", color: Theme.success)
        } else if item.previewAfter != nil {
            BadgeDot(symbol: "eye.fill", color: Theme.accent)
        }
    }
}

struct BadgeDot: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
    }
}

struct AddThumb: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false
    var body: some View {
        Button { model.openPanel() } label: {
            Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                .frame(width: 68, height: 68)
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.chip : .clear))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Thêm ảnh (⌘O)")
    }
}

struct APIPill: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggleAPI() } label: {
            HStack(spacing: 7) {
                Circle().fill(model.apiRunning ? Theme.success : Theme.textTertiary).frame(width: 7, height: 7)
                Text(model.apiRunning ? "API :8765" : "API tắt")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 11).frame(height: 30)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(model.apiRunning ? "API cục bộ đang chạy ở localhost:8765. Bấm để tắt." : "Bấm để bật API cục bộ ở cổng 8765")
    }
}

// MARK: - Tuning column

struct TuningColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tinh chỉnh").font(.system(size: 15, weight: .bold))
                if model.mode == .auto && model.autoStrengths {
                    Text("AUTO").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                Spacer()
                Button { model.showTuning = false } label: {
                    Image(systemName: "sidebar.right").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chip)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                .help("Thu gọn (⌥⌘I)")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: model.mode.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.mode.displayName).font(.system(size: 12, weight: .semibold))
                            Text(model.mode.summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 2)
                    SizeCard()
                    if model.mode == .recover { RecoverCard() }
                    ImageCard()
                    ProtectCard()
                    FaceCard()
                    ExportCard()
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous).strokeBorder(Theme.line))
    }
}

struct CardTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

struct SizeCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: "Kích thước", trailing: model.selected.map { model.outputDimensions(for: $0) })
            Segmented(selection: $model.sizeMode, options: [(.factor, "Tỉ lệ", nil), (.width, "Chiều rộng", nil), (.height, "Chiều cao", nil)],
                      fill: true)
            switch model.sizeMode {
            case .factor:
                NumberRow(label: "Phóng", unit: "x") {
                    TextField("", value: $model.factor, format: .number.precision(.fractionLength(0...2)))
                }
            case .width:
                NumberRow(label: "Chiều rộng", unit: "px") { TextField("", value: $model.targetWidth, format: .number.grouping(.never)) }
            case .height:
                NumberRow(label: "Chiều cao", unit: "px") { TextField("", value: $model.targetHeight, format: .number.grouping(.never)) }
            }
        }
        .card()
    }
}

struct RecoverCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Recover")
            AccentSlider(title: "Creativity", value: $model.creativity, hint: "Cao: vẽ lại nhiều chi tiết hơn (da, tóc, lông).")
            AccentSlider(title: "Resemblance", value: $model.resemblance, hint: "Cao: bám sát ảnh gốc hơn. Trên 70 giữ nguyên chữ.")
        }
        .card()
    }
}

struct ImageCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let manual = !(model.mode == .auto && model.autoStrengths)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Ảnh")
            if model.mode == .auto {
                ToggleRow(title: "Tự chọn độ mạnh", subtitle: "Đo nhiễu, độ nét, độ nén của từng ảnh", isOn: $model.autoStrengths)
            }
            Group {
                if model.mode == .fidelity || model.mode == .auto {
                    AccentSlider(title: "Chi tiết", value: $model.detail, hint: "Thấp: trung thực. Cao: thêm chi tiết sinh ra.")
                }
                AccentSlider(title: "Khử nhiễu", value: $model.denoise)
                AccentSlider(title: "Làm nét", value: $model.sharpen)
                AccentSlider(title: "Khử nén JPEG", value: $model.compression)
                AccentSlider(title: "Tương phản và màu", value: $model.contrast)
                AccentSlider(title: "Kết cấu", value: $model.texture, hint: "Hạt tự nhiên để da và bề mặt không bị bết.")
            }
            .disabled(!manual)
            .opacity(manual ? 1 : 0.45)
        }
        .card()
    }
}

struct ProtectCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            ToggleRow(title: "Giữ chữ", subtitle: "Phím, nhãn, màn hình", isOn: $model.protectText)
            ToggleRow(title: "Giữ màu gốc", subtitle: nil, isOn: $model.preserveColor)
        }
        .card()
    }
}

struct FaceCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Khuôn mặt", trailing: model.selected?.analysis.map { "\($0.faceCount) mặt" })
            ToggleRow(title: "Phục hồi khuôn mặt", subtitle: nil, isOn: $model.faceEnabled)
            if model.faceEnabled {
                Segmented(selection: $model.faceStyle, options: [(.realistic, "Chân thực", nil), (.creative, "Sáng tạo", nil)], fill: true)
                AccentSlider(title: "Độ mạnh", value: $model.face)
                if model.faceStyle == .realistic {
                    AccentSlider(title: "Giữ nét mặt gốc", value: $model.faceFidelity, hint: "Cao: giống người thật hơn, ít chỉnh hơn.")
                }
            }
        }
        .card()
    }
}

struct ExportCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CardTitle(text: "Xuất file")
            KeyValueRow(label: "Định dạng") {
                Picker("", selection: $model.format) {
                    Text("Giữ nguyên").tag(OutputFormat.preserve)
                    Text("PNG").tag(OutputFormat.png)
                    Text("JPEG").tag(OutputFormat.jpg)
                    Text("TIFF").tag(OutputFormat.tiff)
                    Text("HEIC").tag(OutputFormat.heic)
                }
            }
            if model.format == .jpg || model.format == .heic {
                AccentSlider(title: "Chất lượng", value: $model.jpegQuality)
            }
            KeyValueRow(label: "Hậu tố tên") {
                TextField("", text: $model.suffix).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 12, design: .monospaced)).frame(width: 120)
            }
            KeyValueRow(label: "Thư mục") {
                Button { model.chooseOutputFolder() } label: {
                    HStack(spacing: 4) {
                        Text(model.outputFolder?.lastPathComponent ?? "Cạnh ảnh gốc").lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            KeyValueRow(label: "Xử lý bằng") {
                Picker("", selection: $model.device) {
                    ForEach(ComputeDevice.allCases, id: \.self) { d in Text(d.displayName).tag(d) }
                }
            }
        }
        .card()
    }
}

// MARK: - Controls

/// The logo, drawn: a brand-gradient lens barrel around a dark aperture.
struct LogoMark: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Theme.brandRing).rotationEffect(.degrees(-90))
            Circle().fill(Color(hex: 0x0A1020)).padding(size * 0.14)
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: max(0.5, size * 0.012)).padding(size * 0.135)
            Hexagon().fill(Color(hex: 0x05070D)).frame(width: size * 0.36, height: size * 0.36)
            Circle().fill(RadialGradient(colors: [Color(hex: 0x7DD3FC), Color(hex: 0x2563EB)], center: .center,
                                         startRadius: 0, endRadius: size * 0.08))
                .frame(width: size * 0.13, height: size * 0.13)
        }
        .frame(width: size, height: size)
    }
}

struct Hexagon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for k in 0..<6 {
            let a = -Double.pi / 2 + Double(k) * .pi / 3
            let pt = CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
            k == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// Segmented control: a chip well with the selected segment raised on a surface.
struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String, String?)]
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title, symbol) = options[i]
                let on = selection == value
                Button { selection = value } label: {
                    HStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.surface : .clear)
                        .shadow(color: on ? Theme.shadow.opacity(0.5) : .clear, radius: 2, y: 1))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
        .fixedSize(horizontal: !fill, vertical: false)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct IconToggle: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.accentSoft : Theme.chip))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Dock pill; the selected one fills with the accent.
struct PillButton<L: View>: View {
    let selected: Bool
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder let label: L
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Theme.accent : (hovering ? Theme.chipHover : .clear))
                    .shadow(color: selected ? Theme.accent.opacity(0.3) : .clear, radius: 6, y: 2))
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct AccentSlider: View {
    let title: String
    @Binding var value: Double
    var hint: String? = nil
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value.rounded()))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { g in
                let f = CGFloat(min(100, max(0, value)) / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * f), height: 4)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08)))
                        .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
                        .offset(x: (g.size.width - 16) * f)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    guard enabled else { return }
                    value = (min(1, max(0, (v.location.x - 8) / max(1, g.size.width - 16))) * 100).rounded()
                })
            }
            .frame(height: 16)
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value.rounded()))")
        .accessibilityAdjustableAction { dir in
            value = min(100, max(0, value + (dir == .increment ? 5 : -5)))
        }
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

struct KeyValueRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            content.labelsHidden().fixedSize()
        }
    }
}

struct NumberRow<Field: View>: View {
    let label: String
    let unit: String
    @ViewBuilder let field: Field
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            field.textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 80)
                .padding(.horizontal, 8).frame(height: 28)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.line2))
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 18, alignment: .leading)
        }
    }
}

/// brand: the one gradient button (Xem trước). accent: solid accent. quiet: neutral chip.
struct ActionButtonStyle: ButtonStyle {
    enum Kind { case brand, accent, quiet }
    var kind: Kind
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.32, style: .continuous)
        let filled = kind != .quiet && enabled
        return configuration.label
            .font(.system(size: height > 36 ? 13 : 12.5, weight: kind == .quiet ? .semibold : .bold))
            .lineLimit(1)
            .padding(.horizontal, height > 36 ? 18 : 13).frame(height: height)
            .background {
                switch (kind, enabled) {
                case (.brand, true): shape.fill(Theme.brand)
                case (.accent, true): shape.fill(Theme.accent)
                default: shape.fill(Theme.chip)
                }
            }
            .overlay(shape.strokeBorder(filled ? Color.white.opacity(0.2) : Theme.line, lineWidth: 1))
            .foregroundStyle(filled ? Color.white : (enabled ? Theme.textPrimary : Theme.textTertiary))
            .shadow(color: filled ? Theme.accent.opacity(0.3) : .clear, radius: 10, y: 4)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
