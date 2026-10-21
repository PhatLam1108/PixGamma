import Foundation

/// Image measurements used by Auto mode to pick a model and settings.
public struct ImageAnalysis: Codable, Sendable {
    public var width: Int
    public var height: Int
    /// Estimated Gaussian noise sigma on a 0–255 scale (Immerkær).
    public var noiseSigma: Double
    /// Variance of the Laplacian; low means soft/blurry.
    public var sharpness: Double
    /// Ratio of 8×8 block-boundary gradients to in-block gradients (>1 means JPEG blocks).
    public var blockiness: Double
    /// Fraction of pixels in flat regions; high for illustrations, anime and CGI.
    public var flatFraction: Double
    public var faceCount: Int

    // Suggested settings
    public var mode: EnhanceMode
    public var denoise: Double
    public var sharpen: Double
    public var compression: Double
    public var faceRecovery: Double
}

public enum Analyzer {
    public static func analyze(_ image: RGBAImage, faceCount: Int = 0) -> ImageAnalysis {
        // Work on a luma plane at most 1024px on the long side; block statistics
        // need the original grid, so blockiness is measured before downscaling.
        let blockiness = measureBlockiness(image)
        let longSide = max(image.width, image.height)
        let small = longSide > 1024
            ? image.resized(width: max(1, image.width * 1024 / longSide), height: max(1, image.height * 1024 / longSide))
            : image
        let w = small.width, h = small.height
        var luma = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            luma[i] = 0.299 * Double(small.pixels[p]) + 0.587 * Double(small.pixels[p + 1]) + 0.114 * Double(small.pixels[p + 2])
        }

        // Product shots sit on a plain studio backdrop. Measuring flatness over the backdrop
        // made every laptop render look like flat-shaded art, so pixels matching the border
        // colour are left out and only the subject is measured.
        let backdrop = Self.backdropMask(small)

        var noise = 0.0, lapSum = 0.0, lapSq = 0.0, flat = 0, count = 0, hardEdges = 0
        if w > 2 && h > 2 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    if backdrop[y * w + x] { continue }
                    let c = luma[y * w + x]
                    let n = luma[(y - 1) * w + x], s = luma[(y + 1) * w + x]
                    let e = luma[y * w + x + 1], wv = luma[y * w + x - 1]
                    let ne = luma[(y - 1) * w + x + 1], nw = luma[(y - 1) * w + x - 1]
                    let se = luma[(y + 1) * w + x + 1], sw = luma[(y + 1) * w + x - 1]
                    // Immerkær kernel [1 -2 1; -2 4 -2; 1 -2 1]
                    noise += abs(nw + ne + sw + se - 2 * (n + s + e + wv) + 4 * c)
                    let lap = n + s + e + wv - 4 * c
                    lapSum += lap; lapSq += lap * lap
                    if abs(e - wv) < 2 && abs(n - s) < 2 { flat += 1 } else if max(abs(e - wv), abs(n - s)) > 24 { hardEdges += 1 }
                    count += 1
                }
            }
        }
        let sigma = count > 0 ? noise * sqrt(.pi / 2) / (6 * Double(count)) : 0
        let mean = count > 0 ? lapSum / Double(count) : 0
        let variance = count > 0 ? lapSq / Double(count) - mean * mean : 0
        let flatFraction = count > 0 ? Double(flat) / Double(count) : 0
        // Cel-shaded art: what is not flat is mostly hard outlines. 3D renders and photos shade smoothly.
        let hardEdgeShare = count > flat ? Double(hardEdges) / Double(count - flat) : 0

        // Suggestions
        let mode: EnhanceMode
        var denoise = 0.0
        if flatFraction > 0.55 && hardEdgeShare > 0.35 && sigma < 4 && count > (w * h) / 10 {
            mode = .art
        } else if sigma > 6 {
            // Only genuinely noisy images go to the compact denoiser; small but clean photos
            // need the larger photo network to rebuild texture (feathers, skin, fabric).
            mode = .lowres
            denoise = min(1, max(0.2, (sigma - 2) / 10))
        } else {
            mode = .standard
        }
        let compression = blockiness > 1.15 ? min(1, (blockiness - 1.0) * 1.5) : 0
        // Networks already restore edges; extra unsharp masking on top lifted fake strokes on
        // dark keys and made black parts read lighter, so Auto never sharpens on its own.
        let sharpen = 0.0

        return ImageAnalysis(
            width: image.width, height: image.height, noiseSigma: sigma, sharpness: variance,
            blockiness: blockiness, flatFraction: flatFraction, faceCount: faceCount,
            mode: mode, denoise: denoise, sharpen: sharpen, compression: compression,
            faceRecovery: faceCount > 0 && mode != .art ? 0.6 : 0
        )
    }

    /// Pixels close to the dominant border colour (a studio backdrop), when the border is uniform.
    static func backdropMask(_ img: RGBAImage) -> [Bool] {
        let w = img.width, h = img.height
        var mask = [Bool](repeating: false, count: w * h)
        guard w > 8, h > 8 else { return mask }
        var border: [(Int, Int, Int)] = []
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = (y * w + x) * 4
            return (Int(img.pixels[p]), Int(img.pixels[p + 1]), Int(img.pixels[p + 2]))
        }
        for x in 0..<w { border.append(px(x, 0)); border.append(px(x, h - 1)) }
        for y in 0..<h { border.append(px(0, y)); border.append(px(w - 1, y)) }
        func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
        let bg = (median(border.map(\.0)), median(border.map(\.1)), median(border.map(\.2)))
        func close(_ c: (Int, Int, Int)) -> Bool { abs(c.0 - bg.0) < 12 && abs(c.1 - bg.1) < 12 && abs(c.2 - bg.2) < 12 }
        // Only treat it as a backdrop when most of the border agrees.
        guard Double(border.filter(close).count) / Double(border.count) > 0.7 else { return mask }
        for y in 0..<h { for x in 0..<w where close(px(x, y)) { mask[y * w + x] = true } }
        return mask
    }

    /// Mean horizontal gradient on 8-px block boundaries divided by the mean elsewhere.
    static func measureBlockiness(_ image: RGBAImage) -> Double {
        let w = image.width, h = image.height
        guard w >= 32 && h >= 32 else { return 1 }
        var edge = 0.0, edgeN = 0, inner = 0.0, innerN = 0
        let step = max(1, h / 512) // sample rows on large images
        for y in Swift.stride(from: 0, to: h, by: step) {
            let row = y * w * 4
            for x in 1..<w {
                let a = Int(image.pixels[row + (x - 1) * 4 + 1]), b = Int(image.pixels[row + x * 4 + 1])
                let d = Double(abs(a - b))
                if x % 8 == 0 { edge += d; edgeN += 1 } else { inner += d; innerN += 1 }
            }
        }
        guard edgeN > 0, innerN > 0, inner > 0 else { return 1 }
        return (edge / Double(edgeN)) / (inner / Double(innerN))
    }
}
