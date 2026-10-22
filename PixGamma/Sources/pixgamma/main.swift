import ArgumentParser
import Foundation
import PixGammaCore

struct PixGamma: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pixgamma",
        abstract: "Phóng to và làm nét ảnh bằng AI (Core ML, Apple Silicon).",
        version: APIServer.version,
        subcommands: [Upscale.self, Analyze.self, Models.self, Serve.self, Update.self],
        defaultSubcommand: Upscale.self
    )
}

// MARK: - upscale

struct Upscale: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Phóng to một hoặc nhiều ảnh / thư mục.")

    @Argument(help: "File ảnh hoặc thư mục.")
    var inputs: [String]

    @Option(name: [.short, .long], help: "Thư mục lưu kết quả (mặc định: cạnh file gốc, thêm hậu tố -pixgamma).")
    var output: String?

    @Option(name: [.short, .long], help: "auto | standard (std) | fidelity (hf) | art (cgi) | lowres (low) | recover (rec).")
    var model: String = "auto"

    @Option(help: "Hệ số phóng to (1–16).")
    var scale: Double?

    @Option(help: "Chiều rộng đầu ra (px), giữ tỉ lệ.")
    var width: Int?

    @Option(help: "Chiều cao đầu ra (px), giữ tỉ lệ.")
    var height: Int?

    @Option(name: [.customLong("dn"), .customLong("denoise")], help: "Khử nhiễu 0–100.")
    var denoise: Double?

    @Option(name: [.customLong("cr"), .customLong("creativity")], help: "Recover: mức tái tạo chi tiết 0–100 (mặc định 75).")
    var creativity: Double?

    @Option(name: [.customLong("rs"), .customLong("resemblance")], help: "Recover: độ bám ảnh gốc 0–100 (mặc định: 85 cho động vật, cây, chân dung; 40 cho ảnh khác).")
    var resemblance: Double?

    @Option(help: "Recover: mô tả nội dung ảnh (tiếng Anh), ví dụ \"laptop keyboard close-up\".")
    var prompt: String?

    @Option(name: [.customLong("sh"), .customLong("sharpen")], help: "Làm nét 0–100.")
    var sharpen: Double?

    @Option(name: [.customLong("cm"), .customLong("compression")], help: "Khử nén JPEG 0–100.")
    var compression: Double?

    @Option(name: [.customLong("fr"), .customLong("face-recovery")], help: "Phục hồi khuôn mặt 0–100 (0 = tắt).")
    var face: Double?

    @Option(name: [.customLong("dt"), .customLong("detail")], help: "High Fidelity: 0 = trung thực nhất, 100 = nhiều chi tiết sinh thêm nhất.")
    var detail: Double?

    @Option(name: [.customLong("tx"), .customLong("texture")], help: "Thêm hạt/kết cấu tự nhiên 0–100.")
    var texture: Double?

    @Option(name: [.customLong("lc"), .customLong("contrast")], help: "Tương phản cục bộ + độ rực 0–100.")
    var contrast: Double?

    @Option(name: [.customLong("dh"), .customLong("dehalo")], help: "Khử viền sáng quanh cạnh tương phản 0–100.")
    var dehalo: Double = 80

    @Flag(name: .customLong("no-text-protect"), help: "Tắt bước giữ chữ (phím laptop, nhãn, màn hình).")
    var noTextProtect = false

    @Option(name: [.customLong("frc"), .customLong("face-style")], help: "realistic (CodeFormer) | creative (GFPGAN)")
    var faceStyle: String = "realistic"

    @Option(name: [.customLong("frf"), .customLong("face-fidelity")], help: "Mức giữ khuôn mặt gốc 0–100 (realistic).")
    var faceFidelity: Double = 70

    @Flag(name: .customLong("no-color-fix"), help: "Tắt bước giữ màu gốc.")
    var noColorFix = false

    @Option(name: [.short, .customLong("image-format")], help: "preserve | png | jpg | tiff | heic")
    var format: String = "preserve"

    @Option(name: [.customLong("jq"), .customLong("jpeg-quality")], help: "Chất lượng JPEG/HEIC 1–100.")
    var jpegQuality: Double = 95

    @Option(name: [.customLong("res"), .customLong("dpi")], help: "Ghi DPI vào metadata (vd 300).")
    var dpi: Double?

    @Flag(name: [.short, .long], help: "Duyệt cả thư mục con.")
    var recursive = false

    @Flag(help: "Không giữ cấu trúc thư mục con ở đầu ra.")
    var flatten = false

    @Option(help: "Tiền tố tên file.") var prefix: String = ""
    @Option(help: "Hậu tố tên file.") var suffix: String = ""

    @Flag(name: [.customLong("am"), .customLong("append-model")], help: "Thêm tên model và tỉ lệ vào tên file.")
    var appendModel = false

    @Flag(name: [.customLong("se"), .customLong("skip-existing")], help: "Bỏ qua file đã có kết quả.")
    var skipExisting = false

    @Option(name: [.short, .long], help: "gpu (mặc định) | all | ane | cpu")
    var device: String = "gpu"


    @Flag(help: "In kết quả dạng JSON.") var json = false
    @Flag(name: [.short, .long], help: "Không in tiến độ.") var quiet = false

    func validate() throws {
        if [scale != nil, width != nil, height != nil].filter({ $0 }).count > 1 {
            throw ValidationError("Chỉ dùng một trong --scale, --width, --height.")
        }
        if OutputFormat(rawValue: format == "jpeg" ? "jpg" : format == "tif" ? "tiff" : format) == nil {
            throw ValidationError("--image-format không hợp lệ: \(format)")
        }
        if FaceStyle(rawValue: faceStyle) == nil { throw ValidationError("--face-style phải là realistic hoặc creative") }
        if ComputeDevice(rawValue: device) == nil { throw ValidationError("--device không hợp lệ: \(device)") }
        if EnhanceMode.parse(model) == nil {
            throw ValidationError("Model \(model) không có trong PixGamma. Dùng auto/standard/fidelity/art/lowres.")
        }
    }

    func run() throws {
        let size: OutputSize = width.map(OutputSize.width) ?? height.map(OutputSize.height) ?? .factor(scale ?? 4)
        let fmt = OutputFormat(rawValue: format == "jpeg" ? "jpg" : format == "tif" ? "tiff" : format)!
        let naming = NamingOptions(prefix: prefix, suffix: suffix, appendModel: appendModel, flatten: flatten)
        let outDir = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let files = Batch.collect(inputs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, recursive: recursive)
        guard !files.isEmpty else { throw ValidationError("Không tìm thấy ảnh nào.") }

        func pct(_ v: Double?) -> Double? { v.map { min(max($0, 0), 100) / 100 } }
        var results: [[String: Any]] = []
        var failures = 0

        for (index, file) in files.enumerated() {
            let modeName = EnhanceMode.parse(model)?.rawValue ?? model
            let dest = Batch.outputURL(for: file.url, relative: file.relative, outputDirectory: outDir, format: fmt,
                                       naming: naming, modeName: modeName, sizeTag: Batch.sizeTag(size))
            let label = "[\(index + 1)/\(files.count)] \(file.relative)"
            if skipExisting && FileManager.default.fileExists(atPath: dest.path) {
                if !quiet { log("\(label): đã có, bỏ qua") }
                continue
            }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let loaded = try ImageFile.load(file.url)
                var o = UpscaleOptions()
                o.mode = EnhanceMode.parse(model)!
                o.size = size
                if let c = pct(creativity) { o.creativity = c }; if let r = pct(resemblance) { o.resemblance = r }; o.prompt = prompt
                o.denoise = pct(denoise); o.sharpen = pct(sharpen); o.compression = pct(compression); o.faceRecovery = pct(face)
                o.detail = pct(detail); o.texture = pct(texture); o.contrast = pct(contrast)
                o.protectText = !noTextProtect
                o.faceStyle = FaceStyle(rawValue: faceStyle)!
                o.faceFidelity = pct(faceFidelity) ?? 0.7
                o.preserveColor = !noColorFix
                o.device = ComputeDevice(rawValue: device)!
                let q = quiet
                let result = try Upscaler.upscale(loaded.image, options: o) { stage, f in
                    if !q { progressLine("\(label): \(stage)", f) }
                    return true
                }
                if !quiet { FileHandle.standardError.write(Data("\n".utf8)) }
                try ImageFile.save(result.image, to: dest,
                                   settings: ExportSettings(format: fmt, jpegQuality: jpegQuality / 100, dpi: dpi),
                                   sourceProperties: loaded.properties, sourceExtension: file.url.pathExtension)
                let r = result.report
                if !quiet {
                    log("  → \(dest.path)\n    \(r.mode.displayName) · \(r.inputSize[0])×\(r.inputSize[1]) → \(r.outputSize[0])×\(r.outputSize[1]) · "
                        + "model \(r.passes.joined(separator: "+")) · chữ \(r.textRegions) vùng · khuôn mặt \(r.facesRestored)\(r.faceStyle.map { " (\($0.rawValue))" } ?? "") · \(String(format: "%.1f", r.seconds))s")
                    if let p = r.prompt { log("    mô tả: \(p)" + (r.resemblance.map { " · bám ảnh gốc \(Int(($0 * 100).rounded()))" } ?? "")) }
                    if let g = r.recoverGuard { log("    chốt an toàn: \(g)") }
                }
                var entry: [String: Any] = ["input": file.url.path, "output": dest.path]
                if let obj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) { entry["report"] = obj }
                results.append(entry)
            } catch {
                failures += 1
                log("\(label): LỖI — \(error.localizedDescription)")
                results.append(["input": file.url.path, "error": error.localizedDescription])
            }
        }
        if json, let d = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: d, encoding: .utf8)!)
        }
        if failures > 0 { throw ExitCode(1) }
    }
}

// MARK: - analyze

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Phân tích ảnh và in thiết lập Auto đề xuất (JSON).")

    @Argument(help: "File ảnh.") var input: String

    func run() throws {
        let loaded = try ImageFile.load(URL(fileURLWithPath: (input as NSString).expandingTildeInPath))
        let faces = FaceRestorer.detect(loaded.image).count
        let a = Analyzer.analyze(loaded.image, faceCount: faces)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try enc.encode(a), encoding: .utf8)!)
    }
}

// MARK: - models

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Liệt kê model và backend có sẵn.")

    @Flag(help: "In dạng JSON.") var json = false

    func run() throws {
        if json {
            let d = try JSONSerialization.data(withJSONObject: APIServer.modelsInfo(), options: [.prettyPrinted, .sortedKeys])
            print(String(data: d, encoding: .utf8)!)
            return
        }
        print("PixGamma models:")
        for mode in EnhanceMode.allCases {
            print("  \(mode.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(mode.displayName) — \(mode.summary)")
        }
        print("\nFile model:")
        for f in ModelCatalog.allFiles {
            let u = ModelStore.shared.url(for: f)
            print("  \(u == nil ? "✗" : "✓") \(f.padding(toLength: 12, withPad: " ", startingAt: 0)) \(u?.path ?? "không tìm thấy")")
        }
    }
}

// MARK: - serve

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kiểm tra và cài bản PixGamma mới từ GitHub Releases.",
        discussion: "Repo PixGamma công khai nên không cần token. Nếu GitHub báo hết lượt (60 lần mỗi giờ cho mỗi IP), lưu một token GitHub bằng --token hoặc đặt biến PIXGAMMA_GITHUB_TOKEN để có 5.000 lượt mỗi giờ.")

    @Option(help: "Không bắt buộc: lưu token GitHub vào Keychain (nâng giới hạn lượt gọi) rồi kiểm tra.") var token: String?
    @Flag(help: "Tải, kiểm tra SHA-256 và cài bản mới vào PixGamma.app đang chứa lệnh này.") var install = false

    func run() throws {
        if let token { Updater.setToken(token) }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task {
            defer { sem.signal() }
            do {
                let r = try await Updater.latest()
                guard Updater.isNewer(r.version, than: APIServer.version) else {
                    print("Đang dùng bản mới nhất (\(APIServer.version); mới nhất trên GitHub: \(r.version)).")
                    return
                }
                print("Có bản mới: \(r.version) (đang dùng \(APIServer.version))\n")
                print(r.notes)
                guard install else { print("\nCài bằng: pixgamma update --install"); return }
                guard let app = Updater.installedApp else { throw ValidationError("Lệnh này không nằm trong PixGamma.app, hãy cài bằng file DMG.") }
                if (try? Self.shell("/usr/bin/pgrep", ["-x", "PixGammaApp"])) != nil {
                    throw ValidationError("Hãy đóng app PixGamma trước khi cập nhật bằng CLI.")
                }
                let prepared = try await Updater.prepare(r) { p in
                    FileHandle.standardError.write(Data(String(format: "\r  Tải và kiểm tra… %3d%%", Int(p * 100)).utf8))
                }
                try prepared.relaunch(replacing: app, reopen: false)
                print("\nĐã tải \(r.version), đang thay \(app.path) (vài giây sau khi lệnh này kết thúc).")
            } catch { failure = error }
        }
        sem.wait()
        if let failure { throw failure }
    }

    static func shell(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileNoSuchFile) }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Chạy HTTP API cục bộ.")

    @Option(help: "Địa chỉ lắng nghe.") var host: String = "127.0.0.1"
    @Option(name: [.short, .long], help: "Cổng.") var port: UInt16 = 8765

    func run() throws {
        let server = APIServer(host: host, port: port)
        try server.start()
        signal(SIGINT) { _ in Foundation.exit(0) }
        dispatchMain()
    }
}

// MARK: - output helpers

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func progressLine(_ label: String, _ f: Double) {
    let width = 24
    let filled = Int((f * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    FileHandle.standardError.write(Data("\r\u{1B}[K\(label) \(bar) \(Int(f * 100))%".utf8))
}

PixGamma.main()
