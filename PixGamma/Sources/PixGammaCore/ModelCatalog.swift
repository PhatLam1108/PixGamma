import CoreML
import Foundation

/// User-facing enhancement modes.
public enum EnhanceMode: String, CaseIterable, Codable, Sendable {
    case auto
    case standard
    case fidelity
    case art
    case lowres
    case recover

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .standard: return "Standard"
        case .fidelity: return "High Fidelity"
        case .art: return "Art & CGI"
        case .lowres: return "Low Resolution"
        case .recover: return "Recover"
        }
    }

    public var summary: String {
        switch self {
        case .auto: return "Phân tích ảnh rồi tự chọn model và độ mạnh"
        case .standard: return "Ảnh chụp: giữ đúng chất liệu lông, da, vải, không vẽ vân giả (PixGamma Photo v3, SPAN 2x)"
        case .fidelity: return "Chân thực nhất, không bịa chi tiết — thanh Detail trộn RealESRNet ↔ RealESRGAN"
        case .art: return "Tranh vẽ, anime, đồ hoạ, CGI — nét sạch, mảng màu phẳng (anime_6B)"
        case .lowres: return "Ảnh nhỏ, nhiều nhiễu, ảnh web — có thanh khử nhiễu liên tục (general-x4v3 + wdn)"
        case .recover: return "Tái tạo điểm ảnh thật (da, vải, hạt nhám) bằng diffusion — chậm hơn, có thanh Creativity"
        }
    }

    /// Accepts the mode names and short CLI aliases.
    public static func parse(_ s: String) -> EnhanceMode? {
        switch s.lowercased() {
        case "auto": return .auto
        case "std", "standard": return .standard
        case "hf", "fidelity", "high fidelity", "high-fidelity": return .fidelity
        case "art", "cg", "cgi", "anime": return .art
        case "low", "lowres", "low-res", "low resolution": return .lowres
        case "rec", "recover", "gen", "generative": return .recover
        default: return nil
        }
    }
}

/// A concrete Core ML network inside the catalog.
public struct ModelSpec: Sendable, Hashable {
    public let file: String       // base name without extension
    public let scale: Int         // native upscale factor
    public let tile: Int          // input tile edge
}

public enum ModelCatalog {
    /// Native networks per mode, smallest scale first.
    public static func networks(for mode: EnhanceMode) -> [ModelSpec] {
        switch mode {
        case .auto, .standard:
            // Photo: PixGamma Photo v3, 4x-UltraSharpV2 (Kim2091, DAT2) trained on PixGamma's photos
            // without a GAN (training/configs/photo3_us2.yml). Against Photo v2 on 40 held-out web photos:
            // 30.3 vs 29.7 dB and DISTS 0.165 vs 0.164 at 4x, 35.4 vs 34.2 dB and DISTS 0.102 vs 0.104 at 2x.
            // 2x and 3x also run Photo at 4x and scale down: on 8 clean product shots, AI images and
            // banners (half size, back to 2x) that scored 35.4 dB / SSIM 0.968 against 34.5 / 0.960
            // for the SPAN 2x model, which softened detail (0.70 of the original's sharpness).
            // PIXGAMMA_FAST_2X=1 keeps the faster SPAN model (Photo2x) for 2x.
            // Real-ESRGAN x4plus/x2plus remain as the fallback when they are not installed.
            if ModelStore.shared.isAvailable("Photo") {
                return Env.isSet("FAST_2X") && ModelStore.shared.isAvailable("Photo2x")
                    ? [ModelSpec(file: "Photo2x", scale: 2, tile: 256), ModelSpec(file: "Photo", scale: 4, tile: 256)]
                    : [ModelSpec(file: "Photo", scale: 4, tile: 256)]
            }
            return [ModelSpec(file: "Standard2x", scale: 2, tile: 256), ModelSpec(file: "Standard", scale: 4, tile: 256)]
        case .fidelity:
            return [ModelSpec(file: "HighFidelity", scale: 4, tile: 256)]
        case .recover:
            // Clean, faithful base (RealESRNet): GAN bases bake JPEG blocks and smears that
            // diffusion then keeps.
            return ModelStore.shared.isAvailable("HighFidelity")
                ? [ModelSpec(file: "HighFidelity", scale: 4, tile: 256)] : networks(for: .standard)
        case .art:
            return [ModelSpec(file: "ArtCGI", scale: 4, tile: 256)]
        case .lowres:
            return [ModelSpec(file: "LowRes", scale: 4, tile: 256)]
        }
    }

    public static let face = ModelSpec(file: "FaceRestore", scale: 1, tile: 512)

    /// Text regions (run with the 8-way ensemble): PixGamma Photo v1 (PhotoV1, no GAN, so it never
    /// invents strokes; Photo v1 still reads text best), which was trained with text
    /// tiles and beats the Text model on the text benchmark (OCR 90.4 vs 89.2 %, PSNR 30.7 vs
    /// 29.2 dB, sharpness 0.69 vs 0.58) and on real keyboards; then PixGamma's RealPLKSR Text model,
    /// then RealESRNet. PIXGAMMA_TEXT_MODEL=<file> forces another 4x model (benchmarks).
    public static var text: ModelSpec {
        let env = Env.get("TEXT_MODEL")
        for f in [env, "PhotoV1", "Text"].compactMap({ $0 }) where ModelStore.shared.isAvailable(f) {
            return ModelSpec(file: f, scale: 4, tile: 256)
        }
        return networks(for: .fidelity)[0]
    }

    public static var allFiles: [String] {
        ["Photo", "PhotoV1", "Photo2x", "Text", "Standard", "Standard2x", "HighFidelity", "ArtCGI", "LowRes", "FaceRealistic", "FaceRestore"]
    }
}

/// Face recovery style: realistic or creative.
public enum FaceStyle: String, CaseIterable, Codable, Sendable {
    case realistic   // CodeFormer with a fidelity control: keeps the person's identity and skin texture
    case creative    // GFPGAN v1.4: cleaner, more retouched look

    public var file: String { self == .realistic ? "FaceRealistic" : "FaceRestore" }
    public var displayName: String { self == .realistic ? "Chân thực (CodeFormer)" : "Sáng tạo (GFPGAN)" }

    /// Falls back to whichever face model is installed.
    public var available: FaceStyle? {
        if ModelStore.shared.isAvailable(file) { return self }
        let other: FaceStyle = self == .realistic ? .creative : .realistic
        return ModelStore.shared.isAvailable(other.file) ? other : nil
    }
}

public enum ComputeDevice: String, CaseIterable, Codable, Sendable {
    case gpu, all, ane, cpu

    public var units: MLComputeUnits {
        switch self {
        case .all: return .all
        case .ane: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        }
    }

    public var displayName: String {
        switch self {
        case .gpu: return "GPU (nhanh nhất)"
        case .all: return "Tự động"
        case .ane: return "Neural Engine"
        case .cpu: return "CPU"
        }
    }
}

/// Finds and loads compiled models, caching one MLModel per (file, device).
public final class ModelStore: @unchecked Sendable {
    public static let shared = ModelStore()

    private var cache: [String: MLModel] = [:]
    private let lock = NSLock()

    public var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let env = Env.get("MODELS") {
            dirs.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("Models"))
        }
        // CLI installed next to (or symlinked from) the app bundle. argv[0] is just "pixgamma"
        // when run from PATH, so use the absolute executable path.
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        dirs.append(exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Models"))
        dirs.append(Self.appSupport.appendingPathComponent("Models"))
        return dirs
    }

    /// `~/Library/Application Support/PixGamma`. A folder left by Pixora (0.2.1 and earlier),
    /// which holds compiled models and the Recover download, is moved here the first time.
    public static let appSupport: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PixGamma"), legacy = base.appendingPathComponent("Pixora")
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        return dir
    }()

    /// Location of a model, preferring compiled `.mlmodelc`.
    public func url(for file: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            for ext in ["mlmodelc", "mlpackage"] {
                let u = dir.appendingPathComponent("\(file).\(ext)")
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    public func isAvailable(_ file: String) -> Bool { url(for: file) != nil }

    public func model(_ file: String, device: ComputeDevice) throws -> MLModel {
        let key = "\(file)|\(device.rawValue)"
        lock.lock(); defer { lock.unlock() }
        if let m = cache[key] { return m }
        guard var u = url(for: file) else { throw PixGammaError.modelNotFound(file) }
        if u.pathExtension == "mlpackage" {
            u = try compile(u, name: file)
        }
        let config = MLModelConfiguration()
        config.computeUnits = device.units
        // Models marked "compute: gpu" (attention SR such as DAT) hang on the Neural Engine.
        if Self.gpuOnly(u), device == .ane || device == .all { config.computeUnits = .cpuAndGPU }
        let m = try MLModel(contentsOf: u, configuration: config)
        cache[key] = m
        return m
    }

    /// True when the compiled model's metadata asks to stay off the Neural Engine.
    static func gpuOnly(_ compiled: URL) -> Bool {
        guard let data = try? Data(contentsOf: compiled.appendingPathComponent("metadata.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return list.contains { ($0["userDefinedMetadata"] as? [String: String])?["compute"] == "gpu" }
    }

    /// Compiles a source package once into Application Support.
    /// The compiled copy is reused only while it was built from the same package: the stamp
    /// holds the package's real path (symlinks resolved) plus the date and size of its
    /// manifest and weights, so swapping in a different model under the same name recompiles.
    private func compile(_ pkg: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let dir = Self.appSupport.appendingPathComponent("Compiled")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(name).mlmodelc")
        let stampURL = dir.appendingPathComponent("\(name).source")
        let stamp = Self.fingerprint(pkg)
        if fm.fileExists(atPath: dest.path),
           let old = try? String(contentsOf: stampURL, encoding: .utf8), old == stamp {
            return dest
        }
        let tmp = try MLModel.compileModel(at: pkg)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return dest
    }

    private static func fingerprint(_ pkg: URL) -> String {
        let real = pkg.resolvingSymlinksInPath()
        var parts = [real.path]
        for rel in ["Manifest.json", "Data/com.apple.CoreML/weights/weight.bin", "Data/com.apple.CoreML/model.mlmodel"] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: real.appendingPathComponent(rel).path)
            let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            parts.append("\(rel)=\(date)/\(size)")
        }
        return parts.joined(separator: "\n")
    }
}
