import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum OutputFormat: String, CaseIterable, Sendable, Codable {
    case preserve, png, jpg, tiff, heic

    var utType: UTType {
        switch self {
        case .png, .preserve: return .png
        case .jpg: return .jpeg
        case .tiff: return .tiff
        case .heic: return .heic
        }
    }

    public var fileExtension: String {
        switch self {
        case .png, .preserve: return "png"
        case .jpg: return "jpg"
        case .tiff: return "tiff"
        case .heic: return "heic"
        }
    }

    /// Resolves `.preserve` against the source file's extension.
    public static func resolve(_ format: OutputFormat, sourceExtension ext: String) -> OutputFormat {
        guard format == .preserve else { return format }
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpg
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        default: return .png
        }
    }
}

public struct ExportSettings: Sendable, Codable {
    public var format: OutputFormat = .preserve
    public var jpegQuality: Double = 0.95
    /// Pixels-per-inch written to metadata; nil keeps the source value.
    public var dpi: Double? = nil
    public var keepMetadata = true

    public init(format: OutputFormat = .preserve, jpegQuality: Double = 0.95, dpi: Double? = nil, keepMetadata: Bool = true) {
        self.format = format
        self.jpegQuality = jpegQuality
        self.dpi = dpi
        self.keepMetadata = keepMetadata
    }
}

/// A decoded image plus the metadata needed to write a faithful output.
public struct LoadedImage {
    public var image: RGBAImage
    public var sourceType: String?
    public var properties: [String: Any]

    // [String: Any] is not Sendable; it is only read after loading.
    public init(image: RGBAImage, sourceType: String?, properties: [String: Any]) {
        self.image = image
        self.sourceType = sourceType
        self.properties = properties
    }
}

extension LoadedImage: @unchecked Sendable {}

public enum ImageFile {
    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
    ]

    public static func load(_ url: URL) throws -> LoadedImage {
        guard let data = try? Data(contentsOf: url) else { throw PixoraError.imageDecode(url.path) }
        return try load(data: data)
    }

    public static func load(data: Data) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { throw PixoraError.imageDecode("định dạng không hỗ trợ") }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        // CIImage applies EXIF orientation and decodes RAW through Core Image.
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard let ci = CIImage(data: data, options: options) else { throw PixoraError.imageDecode("không giải mã được") }
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let cg = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw PixoraError.imageDecode("không chuyển được sang sRGB")
        }
        let image = try RGBAImage(cgImage: cg)
        return LoadedImage(image: image, sourceType: CGImageSourceGetType(src) as String?, properties: props)
    }

    public static func encode(_ image: RGBAImage, settings: ExportSettings, sourceProperties: [String: Any] = [:], sourceExtension: String = "png") throws -> Data {
        let format = OutputFormat.resolve(settings.format, sourceExtension: sourceExtension)
        guard let cg = image.makeCGImage() else { throw PixoraError.imageEncode("CGImage") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw PixoraError.imageEncode("định dạng \(format.rawValue)")
        }
        var props: [String: Any] = [:]
        if settings.keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if var dict = sourceProperties[key as String] as? [String: Any] {
                    // Pixels were already rotated upright and resized.
                    dict.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
                    dict.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
                    dict.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
                    props[key as String] = dict
                }
            }
        }
        props[kCGImagePropertyOrientation as String] = 1
        if let dpi = settings.dpi ?? (sourceProperties[kCGImagePropertyDPIWidth as String] as? Double) {
            props[kCGImagePropertyDPIWidth as String] = dpi
            props[kCGImagePropertyDPIHeight as String] = dpi
        }
        if format == .jpg || format == .heic {
            props[kCGImageDestinationLossyCompressionQuality as String] = settings.jpegQuality
        }
        if format == .tiff {
            props[kCGImagePropertyTIFFDictionary as String] = (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:])
                .merging([kCGImagePropertyTIFFCompression as String: 8]) { $1 } // Deflate/ZIP
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PixoraError.imageEncode("finalize") }
        return data as Data
    }

    public static func save(_ image: RGBAImage, to url: URL, settings: ExportSettings, sourceProperties: [String: Any] = [:], sourceExtension: String = "png") throws {
        let data = try encode(image, settings: settings, sourceProperties: sourceProperties, sourceExtension: sourceExtension)
        try data.write(to: url, options: .atomic)
    }
}
