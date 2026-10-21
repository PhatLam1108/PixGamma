import CoreGraphics
import Foundation

/// Output size request: a factor, or a target width/height (aspect preserved).
public enum OutputSize: Codable, Sendable, Equatable {
    case factor(Double)
    case width(Int)
    case height(Int)

    public func resolve(width: Int, height: Int) -> (Int, Int) {
        switch self {
        case .factor(let f):
            return (max(1, Int((Double(width) * f).rounded())), max(1, Int((Double(height) * f).rounded())))
        case .width(let w):
            return (w, max(1, Int((Double(height) * Double(w) / Double(width)).rounded())))
        case .height(let h):
            return (max(1, Int((Double(width) * Double(h) / Double(height)).rounded())), h)
        }
    }
}

public struct UpscaleOptions: Codable, Sendable {
    public var mode: EnhanceMode = .auto
    public var size: OutputSize = .factor(4)
    /// 0…1 for all strengths (GUI/CLI use 0–100).
    public var denoise: Double? = nil
    public var sharpen: Double? = nil
    public var compression: Double? = nil
    public var faceRecovery: Double? = nil
    /// High Fidelity: 0 = most faithful (RealESRNet), 1 = most generated detail (RealESRGAN).
    public var detail: Double? = nil
    /// Photographic grain added at the end to avoid a plastic look.
    public var texture: Double? = nil
    /// Local contrast / vibrance 0…1.
    public var contrast: Double? = nil
    /// Re-render detected text with the faithful network (keyboard legends, labels…).
    public var protectText = true
    /// Clip ringing/halos around high-contrast edges, 0…1.
    public var dehalo: Double = 0.8
    public var faceStyle: FaceStyle = .realistic
    /// Realistic face model only: 0 = most restoration, 1 = closest to the original face.
    public var faceFidelity: Double = 0.7
    public var preserveColor = true
    /// Recover mode: how much detail diffusion may redraw, 0…1.
    public var creativity: Double = 0.75
    /// Recover mode: how closely the redraw follows the input, 0…1.
    public var resemblance: Double = 0.4
    /// Recover mode: optional text prompt describing the subject.
    public var prompt: String? = nil
    /// GPU is fastest on Apple Silicon Max/Ultra for these conv nets (measured on M2 Ultra).
    public var device: ComputeDevice = .gpu

    public init() {}

    static let maxFactor = 16.0
}

public struct UpscaleReport: Codable, Sendable {
    public var mode: EnhanceMode
    public var passes: [String]
    public var inputSize: [Int]
    public var outputSize: [Int]
    public var denoise: Double
    public var sharpen: Double
    public var compression: Double
    public var faceRecovery: Double
    public var detail: Double
    public var texture: Double
    public var contrast: Double
    public var textRegions: Int
    /// Text read from the image (Vietnamese and English), top to bottom.
    public var text: [String]?
    public var creativity: Double?
    public var faceStyle: FaceStyle?
    public var facesRestored: Int
    public var seconds: Double
    public var analysis: ImageAnalysis?
}

public struct UpscaleResult: Sendable {
    public var image: RGBAImage
    public var report: UpscaleReport
}

/// Progress stage names are shown in the app and printed by the CLI.
public typealias ProgressHandler = @Sendable (_ stage: String, _ fraction: Double) -> Bool

public enum Upscaler {
    public static func upscale(_ source: RGBAImage, options: UpscaleOptions, progress: ProgressHandler = { _, _ in true }) throws -> UpscaleResult {
        let start = Date()
        let (targetW, targetH) = options.size.resolve(width: source.width, height: source.height)
        let factor = max(Double(targetW) / Double(source.width), Double(targetH) / Double(source.height))
        guard factor <= UpscaleOptions.maxFactor else {
            throw PixGammaError.invalidOption("tỉ lệ tối đa là \(Int(UpscaleOptions.maxFactor))x")
        }

        // Faces are detected on the source, where Vision is fastest.
        let wantsFaces = options.faceRecovery.map { $0 > 0.01 } ?? (options.mode == .auto)
        let faceStyle = options.faceStyle.available
        let faces = wantsFaces && faceStyle != nil ? FaceRestorer.detect(source) : []

        var analysis: ImageAnalysis?
        var mode = options.mode
        var denoise = options.denoise ?? 0.5
        var sharpen = options.sharpen ?? 0
        var compression = options.compression ?? 0
        var faceStrength = options.faceRecovery ?? 0
        var detail = options.detail ?? 0.5
        var texture = options.texture ?? 0
        var contrast = options.contrast ?? 0
        if mode == .auto {
            _ = progress("Phân tích ảnh", 0)
            let a = Analyzer.analyze(source, faceCount: faces.count)
            analysis = a
            mode = a.mode
            denoise = options.denoise ?? (a.mode == .lowres ? a.denoise : 0.5)
            sharpen = options.sharpen ?? a.sharpen
            compression = options.compression ?? a.compression
            faceStrength = options.faceRecovery ?? a.faceRecovery
            // The photo network (RealPLKSR) is the default; the fidelity blend is the fallback
            // when it is not installed.
            if mode == .standard && !ModelStore.shared.isAvailable("Photo") && ModelStore.shared.isAvailable("HighFidelity") {
                mode = .fidelity
                detail = options.detail ?? (faces.isEmpty ? 0.5 : 0.35)
            }
            // Tone stays exactly as shot unless the user asks: Auto adds no contrast or grain
            // (both made blacks look washed out on product photos).
            texture = options.texture ?? 0
            contrast = options.contrast ?? 0
        }

        // Work on opaque RGB; alpha is resized separately (Real-ESRGAN does the same).
        let alpha = source.hasTransparency ? source.alphaPlane() : nil
        var work = source
        if alpha != nil { work.setAlpha(255) }
        work = Filters.reduceCompression(work, strength: compression)
        let colorReference = work

        // Choose passes: the smallest native scale reaching the factor; stack 4x passes beyond 4.
        var passes: [ModelSpec] = []
        if factor > 1.0001 {
            let nets = ModelCatalog.networks(for: mode).filter { ModelStore.shared.isAvailable(modelFile($0, denoise: denoise, device: options.device)) }
            guard let largest = nets.last else {
                throw PixGammaError.modelNotFound(ModelCatalog.networks(for: mode).map(\.file).joined(separator: ", "))
            }
            var reached = 1.0
            while reached < factor - 0.0001 {
                let remaining = factor / reached
                let pick = nets.first { Double($0.scale) >= remaining - 0.0001 } ?? largest
                passes.append(pick)
                reached *= Double(pick.scale)
            }
        }

        let pipelineInput = work
        func runPasses(_ specs: [ModelSpec], on input: RGBAImage, label: String) throws -> (RGBAImage, Bool) {
            var img = input
            var usedDetailInput = false
            for (i, spec) in specs.enumerated() {
                let file = modelFile(spec, denoise: denoise, device: options.device)
                let model = try ModelStore.shared.model(file, device: options.device)
                let engine = try TileEngine(model: model, spec: spec)
                usedDetailInput = usedDetailInput || engine.scalarInputs.contains("detail")
                let stage = specs.count > 1 ? "\(label) \(spec.scale)x (lượt \(i + 1)/\(specs.count))" : "\(label) \(spec.scale)x"
                img = try engine.run(img, controls: ["denoise": denoise, "detail": detail]) { progress(stage, $0) }
            }
            return (img, usedDetailInput)
        }
        let (mainOut, hasDetailInput) = try runPasses(passes, on: pipelineInput, label: "Phóng to")
        work = mainOut

        // High Fidelity's Detail slider: blend the faithful output with the photo network's
        // output (the fixed-weight replacement for network interpolation, which hangs on GPU).
        if mode == .fidelity && !hasDetailInput && detail > 0.02 && !passes.isEmpty {
            let photoNets = ModelCatalog.networks(for: .standard).filter { ModelStore.shared.isAvailable($0.file) }
            if let largest = photoNets.last {
                var photoPasses: [ModelSpec] = [], reached = 1.0
                while reached < factor - 0.0001 {
                    let pick = photoNets.first { Double($0.scale) >= factor / reached - 0.0001 } ?? largest
                    photoPasses.append(pick); reached *= Double(pick.scale)
                }
                var (photoOut, _) = try runPasses(photoPasses, on: pipelineInput, label: "Chi tiết")
                if photoOut.width != work.width || photoOut.height != work.height {
                    photoOut = photoOut.resized(width: work.width, height: work.height)
                }
                let k = Float(min(1, max(0, detail)))
                photoOut.pixels.withUnsafeBufferPointer { g in
                    work.pixels.withUnsafeMutableBufferPointer { o in
                        var i = 0
                        while i < o.count {
                            for c in 0..<3 { o[i + c] = UInt8((Float(o[i + c]) * (1 - k) + Float(g[i + c]) * k).rounded()) }
                            i += 4
                        }
                    }
                }
            }
        }

        if options.dehalo > 0.01 && !passes.isEmpty {
            _ = progress("Khử viền sáng", 0)
            work = Filters.suppressHalo(output: work, source: pipelineInput, strength: options.dehalo)
        }

        if work.width != targetW || work.height != targetH {
            _ = progress("Đổi kích thước", 0)
            work = work.resized(width: targetW, height: targetH)
        }
        // Recover: diffusion redraws fine detail; text and faces keep the network's pixels.
        var textRects: [CGRect]?
        var detection: TextProtector.Detection?
        if mode == .recover && !passes.isEmpty {
            guard GenerativeRefiner.isAvailable else { throw PixGammaError.modelNotFound(GenerativeRefiner.folder) }
            let sx = Double(targetW) / Double(source.width), sy = Double(targetH) / Double(source.height)
            // Same detection as the other modes (also on the network output, before diffusion):
            // on the source alone Vision missed single keycap letters, which diffusion then redrew.
            let det = options.protectText ? TextProtector.analyze(source: colorReference, upscaled: work) : nil
            detection = det
            let found = det?.regions ?? []
            textRects = found
            let protect = found.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            let eyeFaces = FaceRestorer.detect(source).map { $0.scaled(sx) }
            let prompt = options.prompt ?? (eyeFaces.isEmpty ? nil : GenerativeRefiner.portraitPrompt)
            // Face skin: brows to chin, slightly enlarged to cover the cheeks and jaw.
            let skin = eyeFaces.map { f -> CGRect in
                let b = f.faceBox
                return b.insetBy(dx: -b.width * 0.05, dy: -b.height * 0.05)
            }
            let eyes = eyeFaces.flatMap { f -> [CGRect] in
                let d = ((f.rightEye.x - f.leftEye.x) * (f.rightEye.x - f.leftEye.x) + (f.rightEye.y - f.leftEye.y) * (f.rightEye.y - f.leftEye.y)).squareRoot()
                // Eye and brow: skin smoothing and the skin hold skip these so lashes and single
                // brow hairs are drawn freely.
                return [f.leftEye, f.rightEye].map { CGRect(x: $0.x - d * 0.45, y: $0.y - d * 0.8, width: d * 0.9, height: d * 1.05) }
            }
            try GenerativeRefiner.refine(&work, creativity: options.creativity, resemblance: options.resemblance, prompt: prompt, skin: skin, eyes: eyes,
                                         protect: protect, device: options.device) {
                progress("Tái tạo chi tiết (diffusion)", $0)
            }
            if !eyeFaces.isEmpty {
                try GenerativeRefiner.refineEyes(&work, faces: eyeFaces, device: options.device) {
                    progress("Tái tạo mắt", $0)
                }
            }
        }

        var textRegions = 0
        var textBoxes: [CGRect] = []
        if options.protectText && !passes.isEmpty && !(mode == .fidelity && detail < 0.15) {
            // Text found by Vision is re-rendered with the Text model (faithful RealESRNet when
            // it is missing) and feathered in. Tested on keycaps: this keeps strokes straight and thin, while
            // contrast snapping thickened and warped them, and a contrast-based detector
            // mistook leaves, bokeh and feathers for text.
            if detection == nil { detection = TextProtector.analyze(source: colorReference, upscaled: work) }
            let regions = textRects ?? detection!.regions
            if Env.isSet("DEBUG_TEXT") {
                let r = regions.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }.joined(separator: ";")
                    + " LINES " + detection!.lineBoxes.map { String(format: "%.0f,%.0f:%.1f/%.2f", $0.minX, $0.minY, $0.height, TextProtector.inkSpread(colorReference, $0)) }.joined(separator: ";")
                FileHandle.standardError.write(Data("TEXT_REGIONS \(r)\n".utf8))
            }
            if !regions.isEmpty {
                textRegions = try TextProtector.protect(output: &work, source: colorReference, regions: regions, lineBoxes: detection!.lineBoxes, device: options.device) {
                    progress("Giữ chữ (\(regions.count) vùng)", $0)
                }
                if textRegions > 0 { textBoxes = regions }
            }
        }
        if options.preserveColor && !passes.isEmpty {
            _ = progress("Giữ màu gốc", 0)
            work = Filters.preserveColor(output: work, source: colorReference, exclude: textBoxes)
        }
        var restored = 0
        if faceStrength > 0.01 && !faces.isEmpty {
            if !progress("Phục hồi khuôn mặt", 0) { throw CancellationError() }
            let s = Double(targetW) / Double(source.width)
            try FaceRestorer.restore(&work, faces: faces.map { $0.scaled(s) }, strength: faceStrength, style: faceStyle ?? .realistic,
                                     fidelity: options.faceFidelity, device: options.device)
            restored = faces.count
        }
        work = Filters.sharpen(work, strength: sharpen, scale: factor)
        work = Filters.lightAndContrast(work, strength: contrast, scale: factor)
        work = Filters.addTexture(work, strength: texture, scale: factor)
        if let alpha {
            work.setAlpha(plane: resizePlane(alpha, width: source.width, height: source.height, to: targetW, targetH))
        }
        _ = progress("Xong", 1)

        let report = UpscaleReport(
            mode: mode, passes: passes.map { modelFile($0, denoise: denoise) },
            inputSize: [source.width, source.height], outputSize: [targetW, targetH],
            denoise: denoise, sharpen: sharpen, compression: compression, faceRecovery: faceStrength,
            detail: detail, texture: texture, contrast: contrast, textRegions: textRegions,
            text: (detection?.lines.isEmpty ?? true) ? nil : detection?.lines,
            creativity: mode == .recover ? options.creativity : nil, faceStyle: restored > 0 ? faceStyle : nil,
            facesRestored: restored, seconds: Date().timeIntervalSince(start), analysis: analysis
        )
        return UpscaleResult(image: work, report: report)
    }

    /// Low Res uses discrete denoise variants when the dynamic-input model is unavailable.
    static func modelFile(_ spec: ModelSpec, denoise: Double, device: ComputeDevice = .gpu) -> String {
        guard spec.file == "LowRes" else { return spec.file }
        if let m = try? ModelStore.shared.model("LowRes", device: device),
           m.modelDescription.inputDescriptionsByName["denoise"] != nil {
            return "LowRes"
        }
        let level = Int((min(max(denoise, 0), 1) * 4).rounded()) * 25
        let variant = String(format: "LowRes_dn%03d", level)
        return ModelStore.shared.isAvailable(variant) ? variant : "LowRes"
    }
}
