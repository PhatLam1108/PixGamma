import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum Filters {
    /// Restores the source's low-frequency colour and tone after upscaling.
    ///
    /// The low-pass residual `source − downscale(output)` is blurred, upsampled
    /// bilinearly and added back, so detail added by the model is untouched.
    /// `exclude` (source pixels) is left alone: there the correction is mostly the source's blur
    /// and JPEG haze around small glyphs, which would lay a soft glow over re-rendered text.
    static func preserveColor(output: RGBAImage, source: RGBAImage, exclude: [CGRect] = []) -> RGBAImage {
        let w = source.width, h = source.height
        let down = output.resized(width: w, height: h)
        var diff = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                diff[i * 3 + c] = Float(source.pixels[i * 4 + c]) - Float(down.pixels[i * 4 + c])
            }
        }
        diff = boxBlur3(diff, width: w, height: h, radius: 2)
        diff = boxBlur3(diff, width: w, height: h, radius: 2)
        let ramp: Float = 3
        for r in exclude {
            let x0 = max(0, Int(r.minX) - 3), x1 = min(w, Int(r.maxX.rounded(.up)) + 3)
            let y0 = max(0, Int(r.minY) - 3), y1 = min(h, Int(r.maxY.rounded(.up)) + 3)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    // Distance outside the box: 0 inside → full exclusion, fades over `ramp` px.
                    let dx = max(Float(r.minX) - Float(x), Float(x) + 1 - Float(r.maxX), 0)
                    let dy = max(Float(r.minY) - Float(y), Float(y) + 1 - Float(r.maxY), 0)
                    let k = min(1, max(dx, dy) / ramp)
                    let i = (y * w + x) * 3
                    diff[i] *= k; diff[i + 1] *= k; diff[i + 2] *= k
                }
            }
        }

        var out = output
        let W = output.width, H = output.height
        let sx = Float(w) / Float(W), sy = Float(h) / Float(H)
        diff.withUnsafeBufferPointer { d in
            out.pixels.withUnsafeMutableBufferPointer { o in
                for Y in 0..<H {
                    let fy = max(0, min(Float(h - 1), (Float(Y) + 0.5) * sy - 0.5))
                    let y0 = Int(fy), y1 = min(y0 + 1, h - 1), ty = fy - Float(y0)
                    for X in 0..<W {
                        let fx = max(0, min(Float(w - 1), (Float(X) + 0.5) * sx - 0.5))
                        let x0 = Int(fx), x1 = min(x0 + 1, w - 1), tx = fx - Float(x0)
                        let i00 = (y0 * w + x0) * 3, i01 = (y0 * w + x1) * 3
                        let i10 = (y1 * w + x0) * 3, i11 = (y1 * w + x1) * 3
                        let p = (Y * W + X) * 4
                        for c in 0..<3 {
                            let top = d[i00 + c] + (d[i01 + c] - d[i00 + c]) * tx
                            let bot = d[i10 + c] + (d[i11 + c] - d[i10 + c]) * tx
                            let v = Float(o[p + c]) + top + (bot - top) * ty
                            o[p + c] = UInt8(max(0, min(255, v.rounded())))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Removes ringing/halos the network adds around high-contrast edges (white rims around dark
    /// text on a light screen). Each output pixel is limited to the range of the source pixels
    /// around it, widened by a margin, so overshoot beyond what the photo contains is clipped
    /// while textured areas, whose local range is already wide, are left alone.
    static func suppressHalo(output: RGBAImage, source: RGBAImage, strength: Double) -> RGBAImage {
        guard strength > 0.01 else { return output }
        let w = source.width, h = source.height
        // 3x3 local min / max per channel at source resolution.
        var lo = [Float](repeating: 0, count: w * h * 3), hi = lo
        source.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<3 {
                        var mn: UInt8 = 255, mx: UInt8 = 0
                        for dy in -1...1 {
                            let yy = min(max(y + dy, 0), h - 1)
                            for dx in -1...1 {
                                let v = p[(yy * w + min(max(x + dx, 0), w - 1)) * 4 + c]
                                mn = min(mn, v); mx = max(mx, v)
                            }
                        }
                        lo[(y * w + x) * 3 + c] = Float(mn); hi[(y * w + x) * 3 + c] = Float(mx)
                    }
                }
            }
        }
        var out = output
        let W = output.width, H = output.height
        let sx = Float(w) / Float(W), sy = Float(h) / Float(H)
        let k = Float(min(1, max(0, strength)))
        lo.withUnsafeBufferPointer { lo in
            hi.withUnsafeBufferPointer { hi in
                out.pixels.withUnsafeMutableBufferPointer { o in
                    for Y in 0..<H {
                        let fy = max(0, min(Float(h - 1), (Float(Y) + 0.5) * sy - 0.5))
                        let y0 = Int(fy), y1 = min(y0 + 1, h - 1), ty = fy - Float(y0)
                        for X in 0..<W {
                            let fx = max(0, min(Float(w - 1), (Float(X) + 0.5) * sx - 0.5))
                            let x0 = Int(fx), x1 = min(x0 + 1, w - 1), tx = fx - Float(x0)
                            let p = (Y * W + X) * 4
                            for c in 0..<3 {
                                func bil(_ m: UnsafeBufferPointer<Float>) -> Float {
                                    let a = m[(y0 * w + x0) * 3 + c], b = m[(y0 * w + x1) * 3 + c]
                                    let d = m[(y1 * w + x0) * 3 + c], e = m[(y1 * w + x1) * 3 + c]
                                    let t = a + (b - a) * tx, u = d + (e - d) * tx
                                    return t + (u - t) * ty
                                }
                                let mn = bil(lo), mx = bil(hi)
                                let margin = 6 + 0.08 * (mx - mn)
                                let v = Float(o[p + c])
                                let clamped = min(max(v, mn - margin), mx + margin)
                                o[p + c] = UInt8(max(0, min(255, (v + (clamped - v) * k).rounded())))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Separable box blur over an interleaved 3-channel float image.
    static func boxBlur3(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var tmp = src, out = src
        let n = Float(2 * r + 1)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var s: Float = 0
                    for k in -r...r { s += src[(y * w + min(max(x + k, 0), w - 1)) * 3 + c] }
                    tmp[(y * w + x) * 3 + c] = s / n
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var s: Float = 0
                    for k in -r...r { s += tmp[(min(max(y + k, 0), h - 1) * w + x) * 3 + c] }
                    out[(y * w + x) * 3 + c] = s / n
                }
            }
        }
        return out
    }

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    private static func apply(_ image: RGBAImage, _ transform: (CIImage) -> CIImage) -> RGBAImage {
        guard let cg = image.makeCGImage() else { return image }
        let input = CIImage(cgImage: cg)
        let result = transform(input).cropped(to: input.extent)
        var out = image
        out.pixels.withUnsafeMutableBytes { raw in
            context.render(result, toBitmap: raw.baseAddress!, rowBytes: image.rowBytes, bounds: input.extent,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let alpha = image.alphaPlane()
        out.setAlpha(plane: alpha)
        return out
    }

    /// Adds fine luminance grain so smooth model output reads as real photographic texture
    /// (film grain). Grain size follows the upscale factor; amplitude 0…~6 levels.
    static func addTexture(_ image: RGBAImage, strength: Double, scale: Double, seed: UInt64 = 0x9E3779B97F4A7C15) -> RGBAImage {
        guard strength > 0.01 else { return image }
        var out = image
        let w = image.width, h = image.height
        // Grain on a coarser grid (about one cell per source pixel / 2), bilinearly upsampled.
        let cell = max(1.0, scale / 2)
        let gw = Int(Double(w) / cell) + 2, gh = Int(Double(h) / cell) + 2
        var rng = seed
        var grain = [Float](repeating: 0, count: gw * gh)
        for i in 0..<grain.count {
            // Sum of uniforms ≈ Gaussian
            var acc: Float = 0
            for _ in 0..<4 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                acc += Float(rng >> 40) / Float(1 << 24) - 0.5
            }
            grain[i] = acc
        }
        let amp = Float(6 * strength)
        out.pixels.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let fy = Float(Double(y) / cell); let y0 = Int(fy); let ty = fy - Float(y0)
                for x in 0..<w {
                    let fx = Float(Double(x) / cell); let x0 = Int(fx); let tx = fx - Float(x0)
                    let g00 = grain[y0 * gw + x0], g01 = grain[y0 * gw + x0 + 1]
                    let g10 = grain[(y0 + 1) * gw + x0], g11 = grain[(y0 + 1) * gw + x0 + 1]
                    let g = (g00 + (g01 - g00) * tx) * (1 - ty) + (g10 + (g11 - g10) * tx) * ty
                    let p = (y * w + x) * 4
                    // Less grain in deep shadows and highlights, like film.
                    let l = (Float(o[p]) * 0.3 + Float(o[p + 1]) * 0.59 + Float(o[p + 2]) * 0.11) / 255
                    let v = g * amp * (0.35 + 2.6 * l * (1 - l))
                    for c in 0..<3 { o[p + c] = UInt8(max(0, min(255, (Float(o[p + c]) + v).rounded()))) }
                }
            }
        }
        return out
    }

    /// Local contrast ("clarity") plus gentle vibrance.
    /// A large-radius unsharp mask lifts mid-tone contrast without halos on edges.
    static func lightAndContrast(_ image: RGBAImage, strength: Double, scale: Double) -> RGBAImage {
        guard strength > 0.01 else { return image }
        let longSide = Double(max(image.width, image.height))
        return apply(image) { ci in
            let clarity = CIFilter.unsharpMask()
            clarity.inputImage = ci.clampedToExtent()
            clarity.radius = Float(max(8, longSide / 80))
            clarity.intensity = Float(0.45 * strength)
            let vib = CIFilter.vibrance()
            vib.inputImage = clarity.outputImage ?? ci
            vib.amount = Float(0.25 * strength)
            return vib.outputImage ?? ci
        }
    }

    /// Pre-pass for JPEG blockiness.
    static func reduceCompression(_ image: RGBAImage, strength: Double) -> RGBAImage {
        guard strength > 0.01 else { return image }
        return apply(image) { ci in
            let f = CIFilter.noiseReduction()
            f.inputImage = ci.clampedToExtent()
            f.noiseLevel = Float(0.01 + 0.05 * strength)
            f.sharpness = Float(0.4 * (1 - strength))
            return f.outputImage ?? ci
        }
    }

    /// Post-pass sharpening, radius follows output scale.
    static func sharpen(_ image: RGBAImage, strength: Double, scale: Double) -> RGBAImage {
        guard strength > 0.01 else { return image }
        return apply(image) { ci in
            let f = CIFilter.unsharpMask()
            f.inputImage = ci.clampedToExtent()
            f.radius = Float(max(1.0, 0.6 * scale))
            f.intensity = Float(1.2 * strength)
            return f.outputImage ?? ci
        }
    }
}
