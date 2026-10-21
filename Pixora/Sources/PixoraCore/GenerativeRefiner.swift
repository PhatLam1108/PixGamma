import Accelerate
import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

/// Recover mode: re-synthesises real pixel detail (skin pores, hair strands, fibres, grain)
/// on top of the photo network's upscale, like diffusion upscalers do.
///
/// MultiDiffusion over a latent canvas: the upscaled image is VAE-encoded in overlapping
/// 512 px tiles, noised to `strength`, then at every denoising step each 64×64 latent window
/// runs ControlNet Tile (fed the same tile, which locks layout, edges and colour) and the
/// UNet with classifier-free guidance. The noise predictions are feather-averaged into one
/// canvas and a single scheduler step is taken for the whole image, so neighbouring tiles
/// always agree and no seams appear. Decoding is tiled with feathered blending.
///
/// Tuned on portraits, fur and product shots (Realistic Vision 5.1, strength 0.35,
/// ControlNet 1.0): identity and layout stay, skin and hair gain real texture.
/// Text regions keep the photo network's pixels; text protection re-renders them later.
public enum GenerativeRefiner {
    public static let folder = "Recover"
    static let tileL = 64          // latent tile (512 px)
    static let strideL = 48        // latent stride (128 px overlap)
    static let scaleFactor: Float = 0.18215

    /// Prompts are chosen per 512 px tile and must describe texture only: naming eyes or
    /// faces grew extra eyes on cheeks, and "hair strands" drew hair across skin. Tiles whose
    /// centre lies on a face get the skin prompt; eye detail comes from the eye pass.
    public static let skinPrompt =
        "high quality photograph, detailed natural skin texture with fine pores, smooth even skin, sharp focus, natural light"
    /// "Individual hair strands" grew curly flyaways, even across the sky; asking for strands
    /// that follow the hair flow, and forbidding frizz, gave straight, defined hair.
    public static let portraitPrompt =
        "high quality photograph, smooth natural hair strands following the hair flow, fine fabric fibres, sharp focus, natural light"
    public static let defaultPrompt =
        "high quality photograph, sharp focus, highly detailed, realistic skin texture, " +
        "natural hair strands, fine fabric fibres, film grain, natural lighting"
    /// CLIP reads at most 77 tokens; anything after is silently dropped (an 86-token version
    /// lost its hair and droplet terms), so keep this list short.
    public static let negativePrompt =
        "blurry, painting, illustration, cartoon, 3d render, plastic skin, watermark, text, jpeg artifacts, " +
        "oversharpened, halo, extra eyes, face, mouth, teeth, frizzy hair, flyaway hairs, stray hairs, " +
        "tangled hair, hair on background, water droplets, jewelry"
    /// The eye pass works on a crop that does hold an eye, so it must not forbid one.
    static let eyeNegativePrompt =
        "blurry, painting, illustration, cartoon, cgi, 3d render, plastic, deformed iris, cross-eyed, " +
        "extra pupils, jpeg artifacts, oversharpened, halo, lowres, makeup"

    /// Folder with the converted SD 1.5 (+ ControlNet Tile) resources, if installed.
    public static var resourcesURL: URL? {
        let fm = FileManager.default
        for dir in ModelStore.shared.searchDirectories {
            let u = dir.appendingPathComponent(folder)
            if fm.fileExists(atPath: u.appendingPathComponent("ControlledUnet.mlmodelc").path) { return u }
        }
        return nil
    }

    public static var isAvailable: Bool { resourcesURL != nil }

    final class Models {
        let tokenizer: BPETokenizer
        let text: MLModel, unet: MLModel, control: MLModel, encoder: MLModel, decoder: MLModel
        init(_ url: URL, device: ComputeDevice) throws {
            let cfg = MLModelConfiguration()
            // GPU beats the Neural Engine for these shapes on Max/Ultra chips.
            cfg.computeUnits = device == .ane ? .cpuAndNeuralEngine : (device == .cpu ? .cpuOnly : .cpuAndGPU)
            tokenizer = try BPETokenizer(mergesAt: url.appendingPathComponent("merges.txt"),
                                         vocabularyAt: url.appendingPathComponent("vocab.json"))
            let controlDir = url.appendingPathComponent("controlnet")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: controlDir.path)) ?? []).filter { $0.hasSuffix(".mlmodelc") }
            guard let cn = names.first(where: { $0.lowercased().contains("tile") }) ?? names.first else {
                throw PixoraError.modelNotFound("\(GenerativeRefiner.folder)/controlnet")
            }
            text = try MLModel(contentsOf: url.appendingPathComponent("TextEncoder.mlmodelc"), configuration: cfg)
            unet = try MLModel(contentsOf: url.appendingPathComponent("ControlledUnet.mlmodelc"), configuration: cfg)
            control = try MLModel(contentsOf: controlDir.appendingPathComponent(cn), configuration: cfg)
            encoder = try MLModel(contentsOf: url.appendingPathComponent("VAEEncoder.mlmodelc"), configuration: cfg)
            decoder = try MLModel(contentsOf: url.appendingPathComponent("VAEDecoder.mlmodelc"), configuration: cfg)
        }
    }

    static let debugTiming = ProcessInfo.processInfo.environment["PIXORA_DEBUG_TIMING"] != nil
    static func tick(_ label: String, _ start: inout Date) {
        guard debugTiming else { return }
        FileHandle.standardError.write(Data(String(format: "[recover] %@ %.2fs\n", label, Date().timeIntervalSince(start)).utf8))
        start = Date()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (key: String, models: Models)?

    private static func models(device: ComputeDevice) throws -> Models {
        guard let url = resourcesURL else { throw PixoraError.modelNotFound(folder) }
        let key = "\(url.resolvingSymlinksInPath().path)|\(device.rawValue)"
        if let c = cached, c.key == key { return c.models }
        var t = Date()
        let m = try Models(url, device: device)
        tick("load models", &t)
        cached = (key, m)
        return m
    }

    /// - Parameters:
    ///   - image: the photo network's output at the final size.
    ///   - creativity: 0…1 → diffusion strength 0.2…0.8 (0.75 = 0.65, the tuned default).
    ///   - resemblance: 0…1 → ControlNet Tile scale 0.5…1.0; above 0.7 also locks structure.
    ///   - protect: rectangles (output pixels) that keep the input pixels (text).
    public static func refine(_ image: inout RGBAImage, creativity: Double, resemblance: Double = 0.4,
                              prompt: String? = nil, skin: [CGRect] = [], eyes: [CGRect] = [], protect: [CGRect] = [], seed: UInt64 = 1108,
                              device: ComputeDevice = .gpu, progress: (Double) -> Bool = { _ in true }) throws {
        lock.lock(); defer { lock.unlock() }
        let m = try models(device: device)
        // Tuned on a blurry, JPEG-damaged portrait against a commercial generative upscaler:
        // strength 0.65 / ControlNet 0.7 on a clean RealESRNet base rebuilt iris, lashes,
        // single hair strands and pores; 0.35 / 1.0 barely changed the base.
        let c = min(1, max(0, creativity)), r = min(1, max(0, resemblance))
        let strength = Float(0.2 + 0.6 * c)        // default 0.75 → 0.65
        let cnScale = Float(0.5 + 0.5 * r)         // default 0.4 → 0.7
        guard let (outPx, PW, PH) = try diffuse(image, m, strength: strength, cnScale: cnScale,
                                                prompt: prompt ?? defaultPrompt, skin: skin, eyes: eyes, seed: seed, progress: progress) else { return }

        // Structure lock: shapes larger than ~sigma px (glyphs, key outlines, eyes, edges) come
        // from the photo network, only finer detail (pores, strands, grain) from diffusion:
        // out = gen − blur(gen) + blur(base). This stops diffusion from redrawing legends and
        // small text that Vision cannot read, while texture still comes through.
        // Only at high resemblance: the lock also keeps the base's blur and JPEG damage.
        var gen = outPx
        let plane = PH * PW
        if r > 0.7 {
            let sigma = Float(0.8 + 2.2 * (r - 0.7) / 0.3)
            let basePlanar = planar(image, width: PW, height: PH)
            for ch in 0..<3 {
                let rg = ch * plane..<(ch + 1) * plane
                let bg = gaussian(Array(gen[rg]), W: PW, H: PH, sigma: sigma)
                let bb = gaussian(Array(basePlanar[rg]), W: PW, H: PH, sigma: sigma)
            for i in 0..<plane { gen[ch * plane + i] = gen[ch * plane + i] - bg[i] + bb[i] }
            }
        }

        // Write back; protected rectangles keep the input pixels (feathered).
        let keep = protectMask(protect, W: image.width, H: image.height, feather: 24)
        let iw = image.width
        image.pixels.withUnsafeMutableBufferPointer { px in
            for y in 0..<image.height {
                for x in 0..<iw {
                    let i = y * iw + x, k = 1 - keep[i]
                    guard k > 0 else { continue }
                    for ch in 0..<3 {
                        let g = gen[ch * plane + y * PW + x] * 255
                        let o = Float(px[i * 4 + ch])
                        px[i * 4 + ch] = UInt8(min(255, max(0, (o + (g - o) * k).rounded())))
                    }
                }
            }
        }
    }

    public static let eyePrompt =
        "close-up photograph of a human eye, detailed iris texture, sharp natural eyelashes, " +
        "natural catchlight, clear sclera, realistic skin around the eye, sharp focus"

    public static let browPrompt =
        "close-up photograph of a natural eyebrow, individual fine eyebrow hairs, realistic skin, sharp focus"

    /// Eye pass (like ADetailer): each eye is cropped, enlarged to 512 px so diffusion has
    /// enough pixels for the iris pattern, lashes and catchlight, redrawn with an eye prompt
    /// and a strong ControlNet (keeps gaze, iris colour and lid shape), then shrunk and
    /// blended back with a soft elliptical mask. Eyes already larger than 384 px are left to
    /// the main pass.
    /// - Returns: number of eyes refined.
    @discardableResult
    public static func refineEyes(_ image: inout RGBAImage, faces: [FaceLandmarks], strength: Double = 0.5,
                                  seed: UInt64 = 2108, device: ComputeDevice = .gpu,
                                  progress: (Double) -> Bool = { _ in true }) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let m = try models(device: device)
        // Eye crops stay tight (iris and lashes get the most pixels); brows get their own
        // wider, flatter crops above each eye.
        var eyes: [(center: SIMD2<Double>, side: Double, prompt: String)] = []
        for f in faces {
            let d = ((f.rightEye.x - f.leftEye.x) * (f.rightEye.x - f.leftEye.x) + (f.rightEye.y - f.leftEye.y) * (f.rightEye.y - f.leftEye.y)).squareRoot()
            let side = max(24, d * 0.8)
            guard side < 384 else { continue }
            for e in [f.leftEye, f.rightEye] {
                eyes.append((e, side, eyePrompt))
                eyes.append((e - SIMD2(0, d * 0.42), max(28, d * 0.95), browPrompt))
            }
        }
        let size = tileL * 8
        for (n, (c, side, crPrompt)) in eyes.enumerated() {
            let s = Int(side.rounded())
            let x0 = max(0, min(image.width - s, Int(c.x) - s / 2)), y0 = max(0, min(image.height - s, Int(c.y) - s / 2))
            guard s <= image.width, s <= image.height else { continue }
            let crop = image.cropped(x: x0, y: y0, width: s, height: s).resized(width: size, height: size)
            guard let (px, PW, _) = try diffuse(crop, m, strength: Float(strength), cnScale: 1.0, prompt: crPrompt,
                                                negative: eyeNegativePrompt, seed: seed &+ UInt64(n),
                                                progress: { _ in true }) else { continue }
            var gen = RGBAImage(width: size, height: size, fill: 255)
            for i in 0..<(size * size) {
                let y = i / size, x = i % size
                for ch in 0..<3 { gen.pixels[i * 4 + ch] = UInt8(min(255, max(0, (px[ch * PW * PW + y * PW + x] * 255).rounded()))) }
            }
            let small = gen.resized(width: s, height: s)
            image.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<s {
                    for x in 0..<s {
                        let dx = (Double(x) + 0.5) / Double(s) * 2 - 1, dy = (Double(y) + 0.5) / Double(s) * 2 - 1
                        let r = (dx * dx + dy * dy * 1.6).squareRoot()
                        let t = r <= 0.55 ? 1.0 : (r >= 0.95 ? 0.0 : 1 - (r - 0.55) / 0.4)
                        let k = Float(t * t * (3 - 2 * t))
                        guard k > 0 else { continue }
                        let di = ((y0 + y) * image.width + x0 + x) * 4, si = (y * s + x) * 4
                        for ch in 0..<3 {
                            let o = Float(dst[di + ch]), g = Float(small.pixels[si + ch])
                            dst[di + ch] = UInt8(min(255, max(0, (o + (g - o) * k).rounded())))
                        }
                    }
                }
            }
            if !progress(Double(n + 1) / Double(eyes.count)) { throw CancellationError() }
        }
        return eyes.count
    }

    /// MultiDiffusion core. Returns planar [3, PH, PW] floats 0…1 (image edge-padded to PW×PH).
    static func diffuse(_ image: RGBAImage, _ m: Models, strength: Float, cnScale: Float, prompt: String,
                        negative: String = negativePrompt, skin: [CGRect] = [], eyes: [CGRect] = [], seed: UInt64,
                        progress: (Double) -> Bool) throws -> ([Float], Int, Int)? {
        let guidance: Float = 5
        let steps = 24

        var clock = Date()
        // Pad to a multiple of 8 and at least one tile.
        let W = max(image.width, tileL * 8), H = max(image.height, tileL * 8)
        let PW = (W + 7) / 8 * 8, PH = (H + 7) / 8 * 8
        let Lw = PW / 8, Lh = PH / 8
        var base = planar(image, width: PW, height: PH)          // [3, PH, PW] 0…1
        // Skin on a blurry JPEG base is blotchy; diffusion turned the blotches into bumps
        // ("orange peel"). An edge-preserving guided filter flattens low-contrast blotches on
        // skin while eyes, brows and lips (strong edges) and the eye boxes stay untouched.
        if !skin.isEmpty {
            let keepEyes = protectMask(eyes, W: PW, H: PH, feather: 16)
            let onSkin = protectMask(skin, W: PW, H: PH, feather: 32)
            let plane = PW * PH
            let radius = max(4, min(PW, PH) / 160)
            for ch in 0..<3 {
                let r = ch * plane..<(ch + 1) * plane
                let smooth = guidedFilter(Array(base[r]), W: PW, H: PH, radius: radius, eps: 0.0025)
                for i in 0..<plane {
                    let k = onSkin[i] * (1 - keepEyes[i])
                    if k > 0 { base[ch * plane + i] += k * (smooth[i] - base[ch * plane + i]) }
                }
            }
        }
        let xs = origins(Lw), ys = origins(Lh)
        let ov = tileL - strideL
        let tiles = ys.flatMap { y in xs.map { (x: $0, y: y) } }

        // Prompt embeddings → hidden states [2, 768, 1, 77] (negative first).
        let hidden = try hiddenStates(m, negative: negative, positive: prompt)
        // Tiles centred on skin (face boxes, output pixels) use the skin-only prompt.
        let skinHidden = skin.isEmpty ? hidden : try hiddenStates(m, negative: negative, positive: skinPrompt)
        func onSkin(_ t: (x: Int, y: Int)) -> Bool {
            let side = Double(tileL * 8)
            let r = CGRect(x: Double(t.x * 8), y: Double(t.y * 8), width: side, height: side)
            return skin.contains { f in
                let i = f.intersection(r)
                return !i.isNull && i.width * i.height >= 0.35 * side * side
            }
        }
        func tileHidden(_ t: (x: Int, y: Int)) -> MLMultiArray { onSkin(t) ? skinHidden : hidden }
        // Smooth skin gives ControlNet little to hold on to, and at full strength diffusion drew
        // wrinkles and stray hairs on a JPEG-flat cheek. On skin: firmer ControlNet, and after
        // the first ~12% of the steps skin latents are reset to the re-noised base, i.e. skin
        // starts denoising later (a per-pixel lower strength, as in differential diffusion), so
        // pores appear but shapes are not redrawn. A per-step partial pull compounded over the
        // steps and erased the effect entirely.
        let skinMaskRaw = protectMask(skin.map { CGRect(x: $0.minX / 8, y: $0.minY / 8, width: $0.width / 8, height: $0.height / 8) },
                                      W: Lw, H: Lh, feather: 6)
        let eyeMaskL = protectMask(eyes.map { CGRect(x: $0.minX / 8, y: $0.minY / 8, width: $0.width / 8, height: $0.height / 8) },
                                   W: Lw, H: Lh, feather: 3)
        let skinMask = zip(skinMaskRaw, eyeMaskL).map { $0 * (1 - $1) }
        // Flat areas of the base (sky, walls, studio backdrop) also start late: diffusion
        // otherwise painted stray hairs and texture onto empty background.
        let flatMask = flatness(base, W: PW, H: PH, Lw: Lw, Lh: Lh)
        if debugTiming {
            for t in tiles where tileHidden(t) === skinHidden && !skin.isEmpty {
                FileHandle.standardError.write(Data("[recover] skin tile \(t.x * 8),\(t.y * 8)\n".utf8))
            }
            for f in skin { FileHandle.standardError.write(Data("[recover] face box \(f.integral)\n".utf8)) }
        }

        // Tiled VAE encode (latent mean), feather-blended.
        var lat = [Float](repeating: 0, count: 4 * Lh * Lw)
        var wsum = [Float](repeating: 0, count: Lh * Lw)
        for t in tiles {
            let px = crop(base, W: PW, H: PH, x: t.x * 8, y: t.y * 8, size: tileL * 8, channels: 3).map { $0 * 2 - 1 }
            let out = try predict(m.encoder, ["x": array(px, [1, 3, tileL * 8, tileL * 8])], "latent")
            let z = Array(out[0..<(4 * tileL * tileL)]).map { $0 * scaleFactor }
            blend(z, into: &lat, weights: &wsum, x: t.x, y: t.y, tile: tileL, W: Lw, H: Lh, ov: ov, channels: 4)
        }
        normalize(&lat, wsum, channels: 4)
        tick("encode \(tiles.count) tiles", &clock)

        // DPM++ 2M SDE (k-diffusion formulation, Karras sigmas, eta 1). The fresh noise injected
        // at every step yields fine, non-clumping detail (single hair strands, pores); the
        // deterministic 2M solver produced softer hair and blob-like clusters on skin.
        let sampler = SDESampler(steps: steps, strength: strength)
        guard sampler.sigmas.count >= 2 else { return nil }
        // Per latent pixel: how many of the first steps it stays on the re-noised base.
        let nSteps = Float(sampler.sigmas.count - 1)
        let holdUntil = zip(skinMask, flatMask).map { max($0 * 0.12, $1 * 0.35) * nSteps }
        var rng = SplitMix(seed: seed)
        let noise0 = (0..<lat.count).map { _ in rng.gaussian() }
        var latents = zip(lat, noise0).map { $0 + sampler.sigmas[0] * $1 }
        var oldDenoised: [Float]?
        var hLast: Float?

        let stepCount = sampler.sigmas.count - 1
        let totalWork = Double(stepCount * tiles.count + 2 * tiles.count)
        var work = Double(tiles.count)
        let tileCount = 4 * tileL * tileL
        for i in 0..<stepCount {
            let sigma = sampler.sigmas[i], next = sampler.sigmas[i + 1]
            let cIn = 1 / (sigma * sigma + 1).squareRoot()
            let t = sampler.timestep(for: sigma)
            var eps = [Float](repeating: 0, count: latents.count)
            var ew = [Float](repeating: 0, count: Lh * Lw)
            for tile in tiles { try autoreleasepool {
                // Core ML outputs are autoreleased; without a pool per tile they pile up until the
                // whole denoising loop ends (28 GB at 1440 px, killed at 3436 × 5194).
                let th = tileHidden(tile)
                let tcn = onSkin(tile) ? min(1, cnScale + 0.2) : cnScale
                let z = crop(latents, W: Lw, H: Lh, x: tile.x, y: tile.y, size: tileL, channels: 4).map { $0 * cIn }
                let sample = array(z + z, [2, 4, tileL, tileL])
                let ts = array([t, t], [2])
                let cond = crop(base, W: PW, H: PH, x: tile.x * 8, y: tile.y * 8, size: tileL * 8, channels: 3)
                let condArr = array(cond + cond, [2, 3, tileL * 8, tileL * 8])
                let cnOut = try m.control.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "sample": sample, "timestep": ts, "encoder_hidden_states": th, "controlnet_cond": condArr,
                ]))
                var unetIn: [String: Any] = ["sample": sample, "timestep": ts, "encoder_hidden_states": th]
                for name in cnOut.featureNames {
                    guard let r = cnOut.featureValue(for: name)?.multiArrayValue else { continue }
                    unetIn[name] = abs(tcn - 1) < 0.01 ? r : scaled(r, tcn)
                }
                let n = try predict(m.unet, unetIn, "noise_pred")
                var guided = [Float](repeating: 0, count: tileCount)
                for k in 0..<tileCount { guided[k] = n[k] + guidance * (n[tileCount + k] - n[k]) }
                blend(guided, into: &eps, weights: &ew, x: tile.x, y: tile.y, tile: tileL, W: Lw, H: Lh, ov: ov, channels: 4)
                work += 1
                if !progress(work / totalWork) { throw CancellationError() }
            } }
            normalize(&eps, ew, channels: 4)
            let denoised = zip(latents, eps).map { $0 - sigma * $1 }
            if next == 0 {
                latents = denoised
            } else {
                let h = log(sigma) - log(next)            // = t_next − t with t = −log σ
                let etaH = h                              // eta = 1
                let decay = next / sigma * exp(-etaH)
                let w = -expm1(-h - etaH)
                let noiseScale = next * (-expm1(-2 * etaH)).squareRoot()
                var corr: Float = 0
                if let hl = hLast { corr = 0.5 * w * (h / hl) }
                for k in 0..<latents.count {
                    var x = decay * latents[k] + w * denoised[k]
                    if let od = oldDenoised { x += corr * (denoised[k] - od[k]) }
                    latents[k] = x + noiseScale * rng.gaussian()
                }
                do {
                    let plane = Lh * Lw
                    for k in 0..<latents.count {
                        let m = min(1, max(0, holdUntil[k % plane] - Float(i)))
                        guard m > 0 else { continue }
                        latents[k] += m * (lat[k] + next * noise0[k] - latents[k])
                    }
                }
            }
            oldDenoised = denoised
            hLast = log(sigma) - log(max(next, 1e-6))
            tick("step σ=\(String(format: "%.3f", sigma))", &clock)
        }

        // Tiled VAE decode, feather-blended in pixel space.
        var outPx = [Float](repeating: 0, count: 3 * PH * PW)
        var pw = [Float](repeating: 0, count: PH * PW)
        for t in tiles {
            let z = crop(latents, W: Lw, H: Lh, x: t.x, y: t.y, size: tileL, channels: 4).map { $0 / scaleFactor }
            let img = try predict(m.decoder, ["z": array(z, [1, 4, tileL, tileL])], "image").map { (min(1, max(-1, $0)) + 1) / 2 }
            blend(img, into: &outPx, weights: &pw, x: t.x * 8, y: t.y * 8, tile: tileL * 8, W: PW, H: PH, ov: ov * 8, channels: 3)
            work += 1
            _ = progress(min(1, work / totalWork))
        }
        normalize(&outPx, pw, channels: 3)
        tick("decode", &clock)
        return (outPx, PW, PH)
    }

    // MARK: - Text conditioning

    static func hiddenStates(_ m: Models, negative: String, positive: String) throws -> MLMultiArray {
        func encode(_ s: String) throws -> [Float] {
            let ids = m.tokenizer.tokenize(input: s, minCount: 77).tokenIDs
            if ids.count > 77 {
                FileHandle.standardError.write(Data("[recover] prompt has \(ids.count) tokens, CLIP keeps 77: \(s.prefix(40))…\n".utf8))
            }
            var padded = Array(ids.prefix(77))
            if ids.count > 77 { padded[76] = ids.last! }   // keep the end-of-text token
            return try predict(m.text, ["input_ids": array(padded.map(Float.init), [1, 77])], "last_hidden_state")
        }
        let embs = [try encode(negative), try encode(positive)]   // each [77, 768]
        var states = [Float](repeating: 0, count: 2 * 768 * 77)
        for b in 0..<2 {
            for tok in 0..<77 {
                for d in 0..<768 { states[(b * 768 + d) * 77 + tok] = embs[b][tok * 768 + d] }
            }
        }
        return array(states, [2, 768, 1, 77])
    }

    // MARK: - Tiling helpers

    /// Tile origins covering `n` with the configured stride; the last tile is flush with the edge.
    static func origins(_ n: Int) -> [Int] {
        if n <= tileL { return [0] }
        var o = Array(Swift.stride(from: 0, to: n - tileL, by: strideL))
        o.append(n - tileL)
        return o
    }

    /// Planar [3, H, W] floats 0…1, edge-padded to the requested size.
    static func planar(_ img: RGBAImage, width W: Int, height H: Int) -> [Float] {
        var out = [Float](repeating: 0, count: 3 * W * H)
        img.pixels.withUnsafeBufferPointer { s in
            for y in 0..<H {
                let sy = min(y, img.height - 1)
                for x in 0..<W {
                    let si = (sy * img.width + min(x, img.width - 1)) * 4
                    for c in 0..<3 { out[c * W * H + y * W + x] = Float(s[si + c]) / 255 }
                }
            }
        }
        return out
    }

    static func crop(_ a: [Float], W: Int, H: Int, x: Int, y: Int, size: Int, channels: Int) -> [Float] {
        var out = [Float](repeating: 0, count: channels * size * size)
        a.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for c in 0..<channels {
                    for r in 0..<size {
                        let si = c * W * H + (y + r) * W + x, di = (c * size + r) * size
                        d.baseAddress!.advanced(by: di).update(from: s.baseAddress!.advanced(by: si), count: size)
                    }
                }
            }
        }
        return out
    }

    static func blend(_ t: [Float], into acc: inout [Float], weights: inout [Float], x: Int, y: Int,
                      tile: Int, W: Int, H: Int, ov: Int, channels: Int) {
        func ramp(_ i: Int, atStart: Bool, atEnd: Bool) -> Float {
            var v: Float = 1
            if !atStart { v = min(v, (Float(i) + 0.5) / Float(ov)) }
            if !atEnd { v = min(v, (Float(tile - i) - 0.5) / Float(ov)) }
            return max(v, 1e-3)
        }
        let top = y == 0, bottom = y + tile >= H, left = x == 0, right = x + tile >= W
        var wx = [Float](repeating: 1, count: tile)
        for i in 0..<tile { wx[i] = ramp(i, atStart: left, atEnd: right) }
        for r in 0..<tile {
            let wy = ramp(r, atStart: top, atEnd: bottom)
            for col in 0..<tile {
                let w = wy * wx[col], oi = (y + r) * W + x + col
                for c in 0..<channels { acc[c * W * H + oi] += t[(c * tile + r) * tile + col] * w }
                weights[oi] += w
            }
        }
    }

    static func normalize(_ a: inout [Float], _ w: [Float], channels: Int) {
        let n = w.count
        for c in 0..<channels { for i in 0..<n where w[i] > 0 { a[c * n + i] /= w[i] } }
    }

    /// 1 inside protected rectangles, fading to 0 over `feather` pixels outside them.
    static func protectMask(_ rects: [CGRect], W: Int, H: Int, feather: Int) -> [Float] {
        var m = [Float](repeating: 0, count: W * H)
        let f = Double(feather)
        for r in rects {
            let x0 = max(0, Int(r.minX - f)), x1 = min(W, Int(r.maxX + f))
            let y0 = max(0, Int(r.minY - f)), y1 = min(H, Int(r.maxY + f))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                let dy = max(0, max(r.minY - Double(y), Double(y) - r.maxY))
                for x in x0..<x1 {
                    let dx = max(0, max(r.minX - Double(x), Double(x) - r.maxX))
                    let d = (dx * dx + dy * dy).squareRoot()
                    let v = Float(d >= f ? 0 : 1 - d / f)
                    let t = v * v * (3 - 2 * v)
                    if t > m[y * W + x] { m[y * W + x] = t }
                }
            }
        }
        return m
    }

    /// 1 where the base is flat (local std of luma < ~1.2%), averaged down to the latent grid.
    static func flatness(_ base: [Float], W: Int, H: Int, Lw: Int, Lh: Int) -> [Float] {
        let plane = W * H
        var g = [Float](repeating: 0, count: plane)
        for i in 0..<plane { g[i] = (base[i] + base[plane + i] + base[2 * plane + i]) / 3 }
        let mean = guidedBox(g, W: W, H: H, r: 8)
        let sq = guidedBox(g.map { $0 * $0 }, W: W, H: H, r: 8)
        var out = [Float](repeating: 0, count: Lw * Lh)
        for ly in 0..<Lh {
            for lx in 0..<Lw {
                var acc: Float = 0
                for y in (ly * 8)..<min(H, ly * 8 + 8) {
                    for x in (lx * 8)..<min(W, lx * 8 + 8) {
                        let i = y * W + x
                        let sd = max(0, sq[i] - mean[i] * mean[i]).squareRoot()
                        let f = 1 - min(1, sd / 0.012)
                        acc += f * f
                    }
                }
                out[ly * Lw + lx] = acc / 64
            }
        }
        return gaussian(out, W: Lw, H: Lh, sigma: 1)
    }

    /// Self-guided filter (He et al.) on one plane: smooths where local variance ≪ eps,
    /// keeps edges where variance ≫ eps.
    static func guidedBox(_ a: [Float], W: Int, H: Int, r: Int) -> [Float] {
        do {
            // Integral image box mean with edge clamping.
            var integ = [Double](repeating: 0, count: (W + 1) * (H + 1))
            for y in 0..<H {
                var row: Double = 0
                for x in 0..<W {
                    row += Double(a[y * W + x])
                    integ[(y + 1) * (W + 1) + x + 1] = integ[y * (W + 1) + x + 1] + row
                }
            }
            var out = [Float](repeating: 0, count: a.count)
            for y in 0..<H {
                let y0 = max(0, y - r), y1 = min(H, y + r + 1)
                for x in 0..<W {
                    let x0 = max(0, x - r), x1 = min(W, x + r + 1)
                    let sum = integ[y1 * (W + 1) + x1] - integ[y0 * (W + 1) + x1] - integ[y1 * (W + 1) + x0] + integ[y0 * (W + 1) + x0]
                    out[y * W + x] = Float(sum / Double((y1 - y0) * (x1 - x0)))
                }
            }
            return out
        }
    }

    static func guidedFilter(_ p: [Float], W: Int, H: Int, radius r: Int, eps: Float) -> [Float] {
        func box(_ a: [Float]) -> [Float] { guidedBox(a, W: W, H: H, r: r) }
        let mean = box(p)
        let corr = box(p.map { $0 * $0 })
        var a = [Float](repeating: 0, count: p.count), b = a
        for i in 0..<p.count {
            let v = max(0, corr[i] - mean[i] * mean[i])
            a[i] = v / (v + eps)
            b[i] = mean[i] - a[i] * mean[i]
        }
        let ma = box(a), mb = box(b)
        return (0..<p.count).map { ma[$0] * p[$0] + mb[$0] }
    }

    /// Separable Gaussian blur of one float plane (edge-extended).
    static func gaussian(_ src: [Float], W: Int, H: Int, sigma: Float) -> [Float] {
        let r = max(1, Int((sigma * 3).rounded(.up)))
        var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = k.reduce(0, +); k = k.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<H {
                    let row = y * W
                    for x in 0..<W {
                        var acc: Float = 0
                        for j in -r...r { acc += k[j + r] * s[row + min(W - 1, max(0, x + j))] }
                        t[row + x] = acc
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<H {
                    for x in 0..<W {
                        var acc: Float = 0
                        for j in -r...r { acc += k[j + r] * t[min(H - 1, max(0, y + j)) * W + x] }
                        o[y * W + x] = acc
                    }
                }
            }
        }
        return out
    }

    // MARK: - Core ML helpers

    static func array(_ v: [Float], _ shape: [Int]) -> MLMultiArray {
        let a = try! MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        v.withUnsafeBufferPointer { b in
            a.dataPointer.assumingMemoryBound(to: Float.self).update(from: b.baseAddress!, count: v.count)
        }
        return a
    }

    static func predict(_ model: MLModel, _ inputs: [String: Any], _ output: String) throws -> [Float] {
        try autoreleasepool {
            let r = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            guard let a = r.featureValue(for: output)?.multiArrayValue else { throw PixoraError.invalidOption("missing \(output)") }
            return MLShapedArray<Float32>(converting: a).scalars
        }
    }

    /// Scales a ControlNet residual in place (vDSP for fp32; fp16 handled element-wise).
    static func scaled(_ a: MLMultiArray, _ s: Float) -> MLMultiArray {
        let n = a.count
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            var k = s
            vDSP_vsmul(p, 1, &k, p, 1, vDSP_Length(n))
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<n { p[i] = Float16(Float(p[i]) * s) }
        default:
            for i in 0..<n { a[i] = NSNumber(value: a[i].floatValue * s) }
        }
        return a
    }

    /// Karras sigma schedule over SD 1.5's training noise levels, cut at `strength`
    /// (img2img starts part-way down), plus the sigma → timestep map the UNet expects.
    struct SDESampler {
        let sigmas: [Float]
        private let logTable: [Float]          // log σ for t = 0…999

        init(steps: Int, strength: Float) {
            var acp: [Float] = []
            var prod: Float = 1
            let b0 = Float(0.00085).squareRoot(), b1 = Float(0.012).squareRoot()
            for i in 0..<1000 {
                let b = b0 + (b1 - b0) * Float(i) / 999
                prod *= 1 - b * b
                acp.append(prod)
            }
            let table = acp.map { ((1 - $0) / $0).squareRoot() }
            logTable = table.map { log($0) }
            let rho: Float = 7, lo = table[0], hi = table[999]
            var all = (0..<steps).map { i -> Float in
                let r = Float(i) / Float(max(1, steps - 1))
                return pow(pow(hi, 1 / rho) + r * (pow(lo, 1 / rho) - pow(hi, 1 / rho)), rho)
            }
            all.append(0)
            let start = max(0, Int(Float(steps) * (1 - strength)))   // same cut as diffusers img2img
            sigmas = Array(all[start...])
        }

        /// Fractional timestep whose training sigma equals `sigma` (log-linear interpolation).
        func timestep(for sigma: Float) -> Float {
            let ls = log(sigma)
            if ls <= logTable[0] { return 0 }
            if ls >= logTable[999] { return 999 }
            var lo = 0, hi = 999
            while hi - lo > 1 { let mid = (lo + hi) / 2; if logTable[mid] <= ls { lo = mid } else { hi = mid } }
            let w = (ls - logTable[lo]) / (logTable[hi] - logTable[lo])
            return Float(lo) + w
        }
    }

    /// Deterministic Gaussian noise (SplitMix64 + Box–Muller).
    struct SplitMix {
        var state: UInt64
        var spare: Float?
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func gaussian() -> Float {
            if let s = spare { spare = nil; return s }
            let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-12), u2 = Double(next() >> 11) / Double(1 << 53)
            let r = (-2 * log(u1)).squareRoot()
            spare = Float(r * sin(2 * .pi * u2))
            return Float(r * cos(2 * .pi * u2))
        }
    }
}

extension FaceLandmarks {
    /// Box around the face (brows to chin) from the five landmarks, in the same pixel space.
    var faceBox: CGRect {
        let eyes = (leftEye + rightEye) / 2
        let mouth = (mouthLeft + mouthRight) / 2
        let d = rightEye - leftEye, m = mouth - eyes
        let eyeDist = (d.x * d.x + d.y * d.y).squareRoot(), em = (m.x * m.x + m.y * m.y).squareRoot()
        let side = max(eyeDist * 2.2, em * 2.9)
        let c = (eyes + mouth) / 2
        return CGRect(x: c.x - side / 2, y: c.y - side * 0.55, width: side, height: side * 1.1)
    }
}
