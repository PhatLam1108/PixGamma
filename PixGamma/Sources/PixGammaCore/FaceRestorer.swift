import CoreML
import CoreVideo
import Foundation
import Vision
import simd

/// Five facial landmarks in image pixel coordinates (top-left origin).
public struct FaceLandmarks: Sendable {
    public var leftEye: SIMD2<Double>
    public var rightEye: SIMD2<Double>
    public var nose: SIMD2<Double>
    public var mouthLeft: SIMD2<Double>
    public var mouthRight: SIMD2<Double>

    var points: [SIMD2<Double>] { [leftEye, rightEye, nose, mouthLeft, mouthRight] }

    func scaled(_ s: Double) -> FaceLandmarks {
        FaceLandmarks(leftEye: leftEye * s, rightEye: rightEye * s, nose: nose * s, mouthLeft: mouthLeft * s, mouthRight: mouthRight * s)
    }
}

/// Face recovery: Vision landmarks → FFHQ-aligned 512 crop → GFPGAN → feathered paste-back.
/// This follows Real-ESRGAN's `--face_enhance` path, with a strength control.
public enum FaceRestorer {
    /// FFHQ 512×512 reference points used by GFPGAN/facexlib.
    static let template: [SIMD2<Double>] = [
        [192.98138, 239.94708], [318.90277, 240.19360], [256.63416, 314.01935],
        [201.26117, 371.41043], [313.08905, 371.15118],
    ]
    static let size = 512

    public static func detect(_ image: RGBAImage) -> [FaceLandmarks] {
        guard let cg = image.makeCGImage() else { return [] }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        let size = CGSize(width: image.width, height: image.height)
        let H = Double(image.height)

        func pts(_ region: VNFaceLandmarkRegion2D?) -> [SIMD2<Double>] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: size).map { SIMD2(Double($0.x), H - Double($0.y)) }
        }
        func centroid(_ p: [SIMD2<Double>]) -> SIMD2<Double>? {
            p.isEmpty ? nil : p.reduce(.zero, +) / Double(p.count)
        }

        var faces: [FaceLandmarks] = []
        for obs in request.results ?? [] {
            guard let lm = obs.landmarks,
                  let e1 = centroid(pts(lm.leftEye)), let e2 = centroid(pts(lm.rightEye)) else { continue }
            let lips = pts(lm.outerLips)
            guard let ml = lips.min(by: { $0.x < $1.x }), let mr = lips.max(by: { $0.x < $1.x }) else { continue }
            // Nose tip ≈ lowest point of the nose crest / nose outline.
            let noseCandidates = pts(lm.noseCrest) + pts(lm.nose)
            guard let nose = noseCandidates.max(by: { $0.y < $1.y }) else { continue }
            let eyes = [e1, e2].sorted { $0.x < $1.x }
            // Skip tiny faces; GFPGAN gains nothing below ~24 px between the eyes.
            if simd_distance(eyes[0], eyes[1]) < 12 { continue }
            faces.append(FaceLandmarks(leftEye: eyes[0], rightEye: eyes[1], nose: nose, mouthLeft: ml, mouthRight: mr))
        }
        return faces
    }

    /// Least-squares similarity transform (Umeyama) mapping `src` onto `dst`.
    /// Returns (a, b, tx, ty) for x' = a·x − b·y + tx, y' = b·x + a·y + ty.
    static func similarity(from src: [SIMD2<Double>], to dst: [SIMD2<Double>]) -> (Double, Double, Double, Double) {
        let n = Double(src.count)
        let ms = src.reduce(.zero, +) / n, md = dst.reduce(.zero, +) / n
        var sxx = 0.0, sxy = 0.0, varS = 0.0
        for (s, d) in zip(src, dst) {
            let a = s - ms, b = d - md
            sxx += a.x * b.x + a.y * b.y
            sxy += a.x * b.y - a.y * b.x
            varS += a.x * a.x + a.y * a.y
        }
        let a = sxx / varS, b = sxy / varS
        return (a, b, md.x - (a * ms.x - b * ms.y), md.y - (b * ms.x + a * ms.y))
    }

    /// Restores every face in place on the (already upscaled) image.
    /// - Parameters:
    ///   - fidelity: 0…1, only for the realistic (CodeFormer) model; higher keeps more of the original face.
    public static func restore(_ image: inout RGBAImage, faces: [FaceLandmarks], strength: Double, style: FaceStyle = .realistic,
                               fidelity: Double = 0.7, device: ComputeDevice) throws {
        guard strength > 0.01, !faces.isEmpty else { return }
        guard let style = style.available else { throw PixGammaError.modelNotFound("FaceRealistic / FaceRestore") }
        let model = try ModelStore.shared.model(style.file, device: device)
        let inName = model.modelDescription.inputDescriptionsByName.values.first { $0.type == .image }!.name
        let outName = model.modelDescription.outputDescriptionsByName.values.first { $0.type == .image }!.name
        var extra: [String: MLFeatureValue] = [:]
        for d in model.modelDescription.inputDescriptionsByName.values where d.type == .multiArray {
            let a = try MLMultiArray(shape: [1], dataType: .float32)
            a[0] = NSNumber(value: Float(min(max(fidelity, 0), 1)))
            extra[d.name] = MLFeatureValue(multiArray: a)
        }

        let mono = monochromeWeight(image)
        for face in faces {
            let (a, b, tx, ty) = similarity(from: face.points, to: template)
            // Inverse transform: crop → image.
            let det = a * a + b * b
            let ia = a / det, ib = -b / det
            let itx = -(ia * tx - ib * ty), ity = -(ib * tx + ia * ty)

            let crop = try makeBuffer()
            warp(image, into: crop) { x, y in (ia * x - ib * y + itx, ib * x + ia * y + ity) }
            let input = try MLDictionaryFeatureProvider(dictionary: extra.merging([inName: MLFeatureValue(pixelBuffer: crop)]) { $1 })
            guard let restored = try model.prediction(from: input).featureValue(for: outName)?.imageBufferValue else {
                throw PixGammaError.modelIO("FaceRestore output")
            }
            matchColor(restored, to: crop)
            paste(restored, into: &image, a: a, b: b, tx: tx, ty: ty, inverse: (ia, ib, itx, ity), strength: strength, mono: mono)
        }
    }

    private static func makeBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw PixGammaError.modelIO("CVPixelBufferCreate")
        }
        return pb
    }

    @inline(__always)
    private static func sample(_ img: RGBAImage, _ x: Double, _ y: Double) -> SIMD3<Double> {
        let fx = min(max(x, 0), Double(img.width - 1)), fy = min(max(y, 0), Double(img.height - 1))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, img.width - 1), y1 = min(y0 + 1, img.height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func px(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let p = (y * img.width + x) * 4
            return SIMD3(Double(img.pixels[p]), Double(img.pixels[p + 1]), Double(img.pixels[p + 2]))
        }
        let top = px(x0, y0) + (px(x1, y0) - px(x0, y0)) * tx
        let bot = px(x0, y1) + (px(x1, y1) - px(x0, y1)) * tx
        return top + (bot - top) * ty
    }

    private static func warp(_ image: RGBAImage, into pb: CVPixelBuffer, map: (Double, Double) -> (Double, Double)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<size {
            for x in 0..<size {
                let (sx, sy) = map(Double(x) + 0.5, Double(y) + 0.5)
                let c = sample(image, sx - 0.5, sy - 0.5)
                let d = base + y * rb + x * 4
                d[0] = UInt8(c.z); d[1] = UInt8(c.y); d[2] = UInt8(c.x); d[3] = 255
            }
        }
    }

    /// Matches the restored crop's per-channel mean/std to the original crop's centre,
    /// so skin tone and lighting stay the person's own (face models tend to shift them).
    private static func matchColor(_ restored: CVPixelBuffer, to original: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(restored) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(restored, [])
        CVPixelBufferLockBaseAddress(original, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(restored, [])
            CVPixelBufferUnlockBaseAddress(original, .readOnly)
        }
        let r = CVPixelBufferGetBaseAddress(restored)!.assumingMemoryBound(to: UInt8.self)
        let o = CVPixelBufferGetBaseAddress(original)!.assumingMemoryBound(to: UInt8.self)
        let rrb = CVPixelBufferGetBytesPerRow(restored), orb = CVPixelBufferGetBytesPerRow(original)
        // Statistics over the inner face area (template eyes→mouth box, padded).
        let x0 = 150, x1 = 362, y0 = 190, y1 = 420
        var sr = [Double](repeating: 0, count: 3), so = sr, qr = sr, qo = sr
        let n = Double((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                for c in 0..<3 {
                    let a = Double(r[y * rrb + x * 4 + c]), b = Double(o[y * orb + x * 4 + c])
                    sr[c] += a; qr[c] += a * a; so[c] += b; qo[c] += b * b
                }
            }
        }
        var gain = [Double](repeating: 1, count: 3), offset = [Double](repeating: 0, count: 3)
        for c in 0..<3 {
            let mr = sr[c] / n, mo = so[c] / n
            let dr = max(1, sqrt(max(0, qr[c] / n - mr * mr))), dO = max(1, sqrt(max(0, qo[c] / n - mo * mo)))
            // Only correct tone; keep the restored contrast mostly intact.
            gain[c] = min(1.25, max(0.8, 1 + 0.5 * (dO / dr - 1)))
            offset[c] = mo - mr * gain[c]
        }
        for y in 0..<size {
            for x in 0..<size {
                let p = y * rrb + x * 4
                for c in 0..<3 { r[p + c] = UInt8(max(0, min(255, (Double(r[p + c]) * gain[c] + offset[c]).rounded()))) }
            }
        }
    }

    /// How black-and-white (or single-toned, e.g. sepia) the photo is: 1 = monochrome, 0 = colour.
    /// In a toned print chroma is a function of brightness alone, so it is fitted against luma
    /// (quadratic) over the whole image; the leftover chroma is what real colours add.
    static func monochromeWeight(_ image: RGBAImage) -> Double {
        let step = max(1, max(image.width, image.height) / 256)
        var samples: [(y: Double, cb: Double, cr: Double)] = []
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                let p = (y * image.width + x) * 4
                let r = Double(image.pixels[p]), g = Double(image.pixels[p + 1]), b = Double(image.pixels[p + 2])
                let l = 0.299 * r + 0.587 * g + 0.114 * b
                samples.append((l / 255, b - l, r - l))
            }
        }
        guard samples.count > 3 else { return 0 }
        // Normal equations for c ≈ k0 + k1·y + k2·y².
        var m = [[Double]](repeating: [0, 0, 0], count: 3), vb = [0.0, 0, 0], vr = [0.0, 0, 0]
        for s in samples {
            let f = [1, s.y, s.y * s.y]
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += f[i] * f[j] }
                vb[i] += f[i] * s.cb; vr[i] += f[i] * s.cr
            }
        }
        func solve(_ v: [Double]) -> [Double] {
            func det(_ a: [[Double]]) -> Double {
                a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                    + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
            }
            let d = det(m)
            guard abs(d) > 1e-9 else { return [v[0] / m[0][0], 0, 0] }   // flat image: mean only
            return (0..<3).map { k in det(m.indices.map { i in (0..<3).map { j in j == k ? v[i] : m[i][j] } }) / d }
        }
        let kb = solve(vb), kr = solve(vr)
        var resid = 0.0
        for s in samples {
            let f = [1, s.y, s.y * s.y]
            let eb = s.cb - (kb[0] * f[0] + kb[1] * f[1] + kb[2] * f[2])
            let er = s.cr - (kr[0] * f[0] + kr[1] * f[1] + kr[2] * f[2])
            resid += (eb * eb + er * er).squareRoot()
        }
        resid /= Double(samples.count)
        // Scanned prints stay under ~8 (JPEG/scan noise); colour photos are usually 15+.
        let t = min(1, max(0, (resid - 9) / 6))
        return 1 - t * t * (3 - 2 * t)
    }

    /// The colour pasted for one pixel: the restored face, except that on monochrome photos only
    /// its luminance is taken and the existing pixel keeps its own chroma (face models colourise).
    static func blend(old: SIMD3<Double>, restored: SIMD3<Double>, mono: Double) -> SIMD3<Double> {
        guard mono > 0 else { return restored }
        let luma = SIMD3(0.299, 0.587, 0.114)
        let lumaOnly = old + SIMD3(repeating: (restored * luma).sum() - (old * luma).sum())
        return restored + (lumaOnly - restored) * mono
    }

    private static func paste(_ pb: CVPixelBuffer, into image: inout RGBAImage, a: Double, b: Double, tx: Double, ty: Double,
                              inverse: (Double, Double, Double, Double), strength: Double, mono: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let (ro, go, bo) = fmt == kCVPixelFormatType_32ARGB ? (1, 2, 3) : fmt == kCVPixelFormatType_32RGBA ? (0, 1, 2) : (2, 1, 0)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(pb)

        // Bounding box of the crop square in image space.
        let (ia, ib, itx, ity) = inverse
        let corners = [(0.0, 0.0), (Double(size), 0.0), (0.0, Double(size)), (Double(size), Double(size))]
            .map { (ia * $0.0 - ib * $0.1 + itx, ib * $0.0 + ia * $0.1 + ity) }
        let minX = max(0, Int(corners.map(\.0).min()!)), maxX = min(image.width - 1, Int(corners.map(\.0).max()!) + 1)
        let minY = max(0, Int(corners.map(\.1).min()!)), maxY = min(image.height - 1, Int(corners.map(\.1).max()!) + 1)
        guard minX < maxX, minY < maxY else { return }

        let feather = 48.0
        let w = image.width
        for y in minY...maxY {
            for x in minX...maxX {
                // Image → crop.
                let cx = a * (Double(x) + 0.5) - b * (Double(y) + 0.5) + tx
                let cy = b * (Double(x) + 0.5) + a * (Double(y) + 0.5) + ty
                guard cx >= 0, cy >= 0, cx < Double(size) - 1, cy < Double(size) - 1 else { continue }
                // Feathered rounded mask: fade over `feather` px from the crop border.
                let edge = min(cx, cy, Double(size) - 1 - cx, Double(size) - 1 - cy)
                let m = min(1, edge / feather)
                let alpha = m * m * (3 - 2 * m) * strength
                guard alpha > 0.002 else { continue }
                let x0 = Int(cx), y0 = Int(cy), fx = cx - Double(x0), fy = cy - Double(y0)
                func px(_ xx: Int, _ yy: Int) -> SIMD3<Double> {
                    let p = base + yy * rb + xx * 4
                    return SIMD3(Double(p[ro]), Double(p[go]), Double(p[bo]))
                }
                let top = px(x0, y0) + (px(x0 + 1, y0) - px(x0, y0)) * fx
                let bot = px(x0, y0 + 1) + (px(x0 + 1, y0 + 1) - px(x0, y0 + 1)) * fx
                let p = (y * w + x) * 4
                let old = SIMD3(Double(image.pixels[p]), Double(image.pixels[p + 1]), Double(image.pixels[p + 2]))
                let c = blend(old: old, restored: top + (bot - top) * fy, mono: mono)
                for (k, v) in [c.x, c.y, c.z].enumerated() {
                    image.pixels[p + k] = UInt8(max(0, min(255, (old[k] + (v - old[k]) * alpha).rounded())))
                }
            }
        }
    }
}
