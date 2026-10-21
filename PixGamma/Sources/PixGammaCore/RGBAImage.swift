import Accelerate
import CoreGraphics
import Foundation

/// 8-bit RGBA image, sRGB, straight (non-premultiplied) alpha, tightly packed rows.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public var rowBytes: Int { width * 4 }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height * 4))
    }

    /// Draws any CGImage into sRGB RGBA8 and un-premultiplies the result.
    public init(cgImage: CGImage) throws {
        let w = cgImage.width, h = cgImage.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw PixGammaError.imageDecode("cannot create drawing context") }
        var image = RGBAImage(width: w, height: h, pixels: data)
        if image.hasTransparency { image.unpremultiply() }
        self = image
    }

    public var hasTransparency: Bool {
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return true }
            i += 4
        }
        return false
    }

    public func makeCGImage() -> CGImage? {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let alpha: CGImageAlphaInfo = hasTransparency ? .last : .noneSkipLast
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    mutating func unpremultiply() {
        let (w, h, rb) = (width, height, rowBytes)
        pixels.withUnsafeMutableBytes { raw in
            var buf = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rb)
            vImageUnpremultiplyData_RGBA8888(&buf, &buf, vImage_Flags(kvImageNoFlags))
        }
    }

    /// High-quality (Lanczos) resample using vImage.
    public func resized(width newW: Int, height newH: Int) -> RGBAImage {
        if newW == width && newH == height { return self }
        var out = [UInt8](repeating: 0, count: newW * newH * 4)
        var src = pixels
        src.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(newH), width: vImagePixelCount(newW), rowBytes: newW * 4)
                vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return RGBAImage(width: newW, height: newH, pixels: out)
    }

    /// Copy of a sub-rectangle (must lie inside the image).
    /// One of the 8 flips/rotations of the image: bit 0 mirrors left-right, bit 1 top-bottom,
    /// bit 2 transposes. `inverse` undoes the same transform.
    public func dihedral(_ k: Int, inverse: Bool = false) -> RGBAImage {
        if k == 0 { return self }
        let fx = k & 1 != 0, fy = k & 2 != 0, tr = k & 4 != 0
        // Forward: mirror then transpose. Inverse: transpose then mirror (each step is its own inverse).
        let outW = tr ? height : width, outH = tr ? width : height
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<outH {
            for x in 0..<outW {
                var sx: Int, sy: Int
                if inverse {
                    // out = mirror(transpose(self))
                    var mx = x, my = y
                    if fx { mx = outW - 1 - mx }
                    if fy { my = outH - 1 - my }
                    (sx, sy) = tr ? (my, mx) : (mx, my)
                } else {
                    // out = transpose(mirror(self))
                    (sx, sy) = tr ? (y, x) : (x, y)
                    if fx { sx = width - 1 - sx }
                    if fy { sy = height - 1 - sy }
                }
                let s = (sy * width + sx) * 4, d = (y * outW + x) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = pixels[s + 3]
            }
        }
        return RGBAImage(width: outW, height: outH, pixels: out)
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                for row in 0..<h {
                    memcpy(d.baseAddress! + row * w * 4, s.baseAddress! + ((y + row) * width + x) * 4, w * 4)
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// Alpha channel as a separate plane.
    func alphaPlane() -> [UInt8] {
        var a = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) { a[i] = pixels[i * 4 + 3] }
        return a
    }

    mutating func setAlpha(_ value: UInt8) {
        var i = 3
        while i < pixels.count { pixels[i] = value; i += 4 }
    }

    mutating func setAlpha(plane: [UInt8]) {
        for i in 0..<(width * height) { pixels[i * 4 + 3] = plane[i] }
    }
}

/// Resample a single 8-bit plane (used for alpha).
func resizePlane(_ plane: [UInt8], width: Int, height: Int, to newW: Int, _ newH: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: newW * newH)
    var src = plane
    src.withUnsafeMutableBytes { s in
        out.withUnsafeMutableBytes { d in
            var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(newH), width: vImagePixelCount(newW), rowBytes: newW)
            vImageScale_Planar8(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling))
        }
    }
    return out
}

public enum PixGammaError: LocalizedError {
    case imageDecode(String)
    case imageEncode(String)
    case modelNotFound(String)
    case modelIO(String)
    case invalidOption(String)

    public var errorDescription: String? {
        switch self {
        case .imageDecode(let m): return "Không đọc được ảnh: \(m)"
        case .imageEncode(let m): return "Không ghi được ảnh: \(m)"
        case .modelNotFound(let m): return "Không tìm thấy model: \(m)"
        case .modelIO(let m): return "Lỗi model: \(m)"
        case .invalidOption(let m): return "Tuỳ chọn không hợp lệ: \(m)"
        }
    }
}
