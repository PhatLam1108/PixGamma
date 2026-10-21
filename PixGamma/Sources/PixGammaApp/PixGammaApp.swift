import AppKit
import PixGammaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PixGammaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("PixGamma") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .sheet(isPresented: $updates.showing) { UpdateSheet().environmentObject(updates) }
                .onAppear { updates.checkOnLaunch() }
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Kiểm tra cập nhật…") { updates.checkNow() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Mở ảnh…") { model.openPanel() }.keyboardShortcut("o")
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

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: Theme.sidebarWidth)
            Divider().overlay(Theme.hairline)
            Canvas(dropTargeted: dropTargeted)
            Divider().overlay(Theme.hairline)
            Inspector().frame(width: Theme.inspectorWidth)
        }
        .background(Theme.base)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .ignoresSafeArea(.container, edges: .top)
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

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leaves room for the traffic lights in the hidden title bar.
            HStack(alignment: .firstTextBaseline) {
                Text("PixGamma").font(.system(size: 15, weight: .semibold))
                Spacer()
                IconButton(symbol: "plus", help: "Thêm ảnh (⌘O)") { model.openPanel() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 40)
            .padding(.bottom, 10)

            HStack {
                Text("Ảnh").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if !model.items.isEmpty {
                    Text("\(model.items.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Text("Chưa có ảnh").font(.system(size: 12, weight: .medium))
                    Text("Kéo ảnh hoặc thư mục vào cửa sổ").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in
                            Button { model.selection = item.id } label: {
                                ItemRow(item: item, selected: model.selection == item.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.url.lastPathComponent)
                                .contextMenu {
                                    Button("Xoá khỏi danh sách") { model.remove(item) }
                                    if let u = item.exportedURL {
                                        Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Divider().overlay(Theme.hairline)
            APIStatus().padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Theme.panel)
    }
}

struct ItemRow: View {
    @ObservedObject var item: ImageItem
    @EnvironmentObject var model: AppModel
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Theme.raised
                if let t = item.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(model.outputDimensions(for: item))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
                StatusText(status: item.status)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .fill(selected ? Theme.accentSoft : (hovering ? Theme.raised.opacity(0.6) : .clear))
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(selected ? Theme.accent.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct StatusText: View {
    let status: String
    var body: some View {
        let color: Color = status.hasPrefix("Lỗi") ? Theme.danger : status == "Đã xuất" ? Theme.success : Theme.textTertiary
        Text(status).font(.system(size: 10)).foregroundStyle(color).lineLimit(1)
    }
}

struct APIStatus: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network").font(.system(size: 11)).foregroundStyle(model.apiRunning ? Theme.success : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("API cục bộ").font(.system(size: 11, weight: .medium))
                Text(model.apiRunning ? "localhost:8765" : "Đang tắt").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.apiRunning }, set: { _ in model.toggleAPI() }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

// MARK: - Canvas

enum ZoomLevel: String, CaseIterable, Identifiable {
    case fit = "Vừa khung", actual = "100%", double = "200%"
    var id: String { rawValue }
}

struct Canvas: View {
    @EnvironmentObject var model: AppModel
    let dropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            CanvasHeader()
            ZStack {
                Theme.canvas
                if let item = model.selected {
                    ItemCanvas(item: item)
                } else {
                    EmptyCanvas()
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Theme.radiusCard)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            ActionBar()
        }
    }
}

struct CanvasHeader: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if let item = model.selected {
                Text(item.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(model.outputDimensions(for: item)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            } else {
                Text(" ").font(.system(size: 12))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .padding(.top, 8)
        .background(Theme.base)
    }
}

struct EmptyCanvas: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 6) {
                Text("Thả ảnh vào đây để bắt đầu").font(.system(size: 17, weight: .semibold))
                Text("JPEG, PNG, HEIC, TIFF, RAW. Có thể thả cả thư mục.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Button { model.openPanel() } label: {
                Text("Chọn ảnh").font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct ItemCanvas: View {
    @ObservedObject var item: ImageItem
    @State private var split: CGFloat = 0.5
    @State private var zoom: ZoomLevel = .fit

    var body: some View {
        ZStack {
            if let after = item.previewAfter, let before = item.previewBefore {
                CompareView(before: before, after: after, split: $split, zoom: zoom)
            } else if let display = item.display {
                ZoomableImage(image: display, zoom: zoom)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack {
                HStack(alignment: .top) {
                    if item.previewAfter != nil {
                        CanvasChip(text: "Gốc")
                        Spacer()
                        CanvasChip(text: "PixGamma")
                    } else {
                        Spacer()
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if let r = item.report {
                        ReportStrip(report: r)
                    } else if let a = item.analysis {
                        AnalysisStrip(analysis: a)
                    }
                    Spacer()
                    Picker("", selection: $zoom) {
                        ForEach(ZoomLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220).controlSize(.small)
                }
            }
            .padding(14)
        }
    }
}

struct ZoomableImage: View {
    let image: NSImage
    let zoom: ZoomLevel

    var body: some View {
        GeometryReader { geo in
            let px = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
            if zoom == .fit {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(28)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let scale: CGFloat = zoom == .actual ? 1 : 2
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(zoom == .double ? .none : .high)
                        .frame(width: px.width * scale / (NSScreen.main?.backingScaleFactor ?? 2),
                               height: px.height * scale / (NSScreen.main?.backingScaleFactor ?? 2))
                }
            }
        }
    }
}

/// Before/after with a draggable divider; both layers share one frame so they line up exactly.
struct CompareView: View {
    let before: NSImage
    let after: NSImage
    @Binding var split: CGFloat
    let zoom: ZoomLevel

    var body: some View {
        GeometryReader { geo in
            let aspect = after.size.width / max(after.size.height, 1)
            let fitW = min(geo.size.width - 56, (geo.size.height - 56) * aspect)
            let scale: CGFloat = zoom == .fit ? 1 : (zoom == .actual ? 1.6 : 2.4)
            let w = fitW * scale, h = w / aspect
            ZStack(alignment: .leading) {
                Image(nsImage: before).resizable().interpolation(.high)
                Image(nsImage: after).resizable().interpolation(.high)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: w * (1 - split)).offset(x: w * split)
                    }
                Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1.5).offset(x: w * split - 0.75)
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "chevron.left.chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.base))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .offset(x: w * split - 14)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                split = min(1, max(0, v.location.x / w))
            })
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
    }
}

struct CanvasChip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct ReportStrip: View {
    let report: UpscaleReport
    var body: some View {
        HStack(spacing: 12) {
            Label(report.mode.displayName, systemImage: "cpu")
            Label("\(report.facesRestored) mặt", systemImage: "face.smiling")
            Label("\(report.textRegions) vùng chữ", systemImage: "textformat")
            Label(String(format: "%.1f giây", report.seconds), systemImage: "timer")
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct AnalysisStrip: View {
    let analysis: ImageAnalysis
    var body: some View {
        HStack(spacing: 12) {
            Label("Gợi ý: \(analysis.mode.displayName)", systemImage: "wand.and.stars")
            Label("Nhiễu \(String(format: "%.1f", analysis.noiseSigma))", systemImage: "aqi.medium")
            Label("\(analysis.faceCount) mặt", systemImage: "face.smiling")
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct ActionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.busy {
                ProgressView(value: model.progress).progressViewStyle(.linear).frame(width: 180).tint(Theme.accent)
                Text(model.stage).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Button("Huỷ") { model.cancel() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Text(model.stage.isEmpty ? "Sẵn sàng" : model.stage)
                    .font(.system(size: 12))
                    .foregroundStyle(model.stage.hasPrefix("Lỗi") ? Theme.danger : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { model.preview() } label: {
                Label("Xem trước", systemImage: "eye").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.selected == nil || model.busy)
            .help("Chạy thiết lập hiện tại trên vùng giữa ảnh (⌘P)")

            Button { model.exportAll() } label: {
                Label(model.items.count > 1 ? "Xuất \(model.items.count) ảnh" : "Xuất ảnh", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.items.isEmpty || model.busy)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.base)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ModelSection()
                SizeSection()
                TuningSection()
                FaceSection()
                ExportSection()
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 24)
        }
        .background(Theme.panel)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }
}

struct ModelSection: View {
    @EnvironmentObject var model: AppModel
    private let icons: [EnhanceMode: String] = [
        .auto: "wand.and.stars", .standard: "photo", .fidelity: "scope", .art: "paintpalette", .lowres: "square.grid.3x3",
        .recover: "sparkles",
    ]
    private let short: [EnhanceMode: String] = [
        .auto: "Tự phân tích và chọn",
        .standard: "Ảnh chụp thường",
        .fidelity: "Chân thực, giữ chi tiết thật",
        .art: "Tranh, anime, đồ hoạ",
        .lowres: "Ảnh nhỏ, nhiều nhiễu",
        .recover: "Tái tạo da, tóc, mắt (diffusion)",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Model AI")
            VStack(spacing: 4) {
                ForEach(EnhanceMode.allCases.filter { $0 != .recover || GenerativeRefiner.isAvailable }, id: \.self) { mode in
                    ModelCard(icon: icons[mode] ?? "photo", title: mode.displayName, subtitle: short[mode] ?? "",
                              selected: model.mode == mode) { model.mode = mode }
                }
            }
            if model.mode == .auto {
                Toggle("Tự chọn độ mạnh", isOn: $model.autoStrengths)
                    .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                    .padding(.top, 4)
            }
        }
    }
}

struct ModelCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusCard)
                    .fill(selected ? Theme.accentSoft : (hovering ? Theme.raised : Theme.raised.opacity(0.45)))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(selected ? Theme.accent.opacity(0.55) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SizeSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Kích thước")
            Picker("", selection: $model.sizeMode) {
                Text("Tỉ lệ").tag(SizeMode.factor)
                Text("Chiều rộng").tag(SizeMode.width)
                Text("Chiều cao").tag(SizeMode.height)
            }
            .pickerStyle(.segmented).labelsHidden()

            switch model.sizeMode {
            case .factor:
                HStack(spacing: 6) {
                    ForEach([1.0, 2, 4, 6], id: \.self) { f in
                        ChipButton(title: "\(Int(f))x", selected: model.factor == f) { model.factor = f }
                    }
                }
                HStack {
                    Text("Tuỳ chỉnh").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TextField("", value: $model.factor, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                    Text("x").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            case .width:
                PixelField(label: "Chiều rộng", value: $model.targetWidth)
            case .height:
                PixelField(label: "Chiều cao", value: $model.targetHeight)
            }
            if let item = model.selected {
                Text(model.outputDimensions(for: item)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct PixelField: View {
    let label: String
    @Binding var value: Int
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer()
            TextField("", value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 88).multilineTextAlignment(.trailing)
            Text("px").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct TuningSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let manual = !(model.mode == .auto && model.autoStrengths)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "Tinh chỉnh")
                Spacer()
                if !manual { Text("Auto").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            if model.mode == .recover {
                ValueSlider(title: "Creativity", value: $model.creativity, hint: "Cao: vẽ lại nhiều chi tiết hơn (da, tóc, lông).")
                ValueSlider(title: "Resemblance", value: $model.resemblance, hint: "Cao: bám sát ảnh gốc hơn.")
            }
            Group {
                if model.mode == .fidelity || model.mode == .auto {
                    ValueSlider(title: "Chi tiết", value: $model.detail, hint: "Thấp: trung thực. Cao: thêm chi tiết sinh ra.")
                }
                ValueSlider(title: "Khử nhiễu", value: $model.denoise)
                ValueSlider(title: "Làm nét", value: $model.sharpen)
                ValueSlider(title: "Khử nén JPEG", value: $model.compression)
                ValueSlider(title: "Tương phản và màu", value: $model.contrast)
                ValueSlider(title: "Kết cấu", value: $model.texture, hint: "Thêm hạt tự nhiên để da và bề mặt không bị bết.")
            }
            .disabled(!manual)
            .opacity(manual ? 1 : 0.45)

            VStack(spacing: 8) {
                SwitchRow(title: "Giữ chữ", subtitle: "Phím laptop, nhãn, màn hình", isOn: $model.protectText)
                SwitchRow(title: "Giữ màu gốc", subtitle: nil, isOn: $model.preserveColor)
            }
        }
    }
}

struct FaceSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Khuôn mặt")
            SwitchRow(title: "Phục hồi khuôn mặt", subtitle: nil, isOn: $model.faceEnabled)
            if model.faceEnabled {
                Picker("", selection: $model.faceStyle) {
                    Text("Chân thực").tag(FaceStyle.realistic)
                    Text("Sáng tạo").tag(FaceStyle.creative)
                }
                .pickerStyle(.segmented).labelsHidden()
                ValueSlider(title: "Độ mạnh", value: $model.face)
                if model.faceStyle == .realistic {
                    ValueSlider(title: "Giữ nét mặt gốc", value: $model.faceFidelity, hint: "Cao: giống người thật hơn, ít chỉnh sửa hơn.")
                }
            }
        }
    }
}

struct ExportSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Xuất file")
            LabeledRow(label: "Định dạng") {
                Picker("", selection: $model.format) {
                    Text("Giữ nguyên").tag(OutputFormat.preserve)
                    Text("PNG").tag(OutputFormat.png)
                    Text("JPEG").tag(OutputFormat.jpg)
                    Text("TIFF").tag(OutputFormat.tiff)
                    Text("HEIC").tag(OutputFormat.heic)
                }
                .labelsHidden().frame(width: 130)
            }
            if model.format == .jpg || model.format == .heic {
                ValueSlider(title: "Chất lượng", value: $model.jpegQuality)
            }
            LabeledRow(label: "Hậu tố tên") {
                TextField("", text: $model.suffix).textFieldStyle(.roundedBorder).frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư mục lưu").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(model.outputFolder?.lastPathComponent ?? "Cạnh ảnh gốc")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Đổi") { model.chooseOutputFolder() }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(8)
                .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.radiusControl))
            }
            LabeledRow(label: "Xử lý bằng") {
                Picker("", selection: $model.device) {
                    ForEach(ComputeDevice.allCases, id: \.self) { d in Text(d.displayName).tag(d) }
                }
                .labelsHidden().frame(width: 130)
            }
        }
    }
}

// MARK: - Controls

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text("\(Int(value.rounded()))").font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: 0...100).controlSize(.small)
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SwitchRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer()
            content
        }
    }
}

struct ChipButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(selected ? Theme.accent : Theme.raised))
                .foregroundStyle(selected ? Color.white : Theme.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(hovering ? Theme.hover : Theme.raised))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(enabled ? Theme.accent : Theme.raised))
            .foregroundStyle(enabled ? Color.white : Theme.textTertiary)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(configuration.isPressed ? Theme.hover : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(Theme.hairline))
            .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
