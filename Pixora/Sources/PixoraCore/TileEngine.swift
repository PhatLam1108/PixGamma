import CoreML
import CoreVideo
import Foundation

/// Runs a fixed-size image-to-image Core ML network over an arbitrarily large image.
///
/// Tiles overlap by `pad` pixels of context on each side; only each tile's centre is
/// kept (like Real-ESRGAN's tile_pad), so every
/// output pixel comes from exactly one tile and seams stay invisible.
final class TileEngine {
    let model: MLModel
    let tile: Int
    let scale: Int
    let pad: Int
    let batchSize: Int
    let inputName: String
    let outputName: String
    /// Scalar control inputs the network exposes (e.g. "denoise", "detail").
    let scalarInputs: Set<String>

    init(model: MLModel, spec: ModelSpec, pad: Int = 16, batchSize: Int = 4) throws {
        self.model = model
        self.scale = spec.scale
        self.pad = pad
        self.batchSize = batchSize
        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.values.first(where: { $0.type == .image }),
              let constraint = input.imageConstraint,
              let output = desc.outputDescriptionsByName.values.first(where: { $0.type == .image }) else {
            throw PixoraError.modelIO("model không có input/output dạng ảnh")
        }
        self.tile = constraint.pixelsWide
        self.inputName = input.name
        self.outputName = output.name
        self.scalarInputs = Set(desc.inputDescriptionsByName.values.filter { $0.type == .multiArray }.map(\.name))
    }

    /// - Parameter progress: called with fraction 0...1 after each batch; return false to cancel.
    func run(_ image: RGBAImage, controls: [String: Double] = [:], progress: (Double) -> Bool = { _ in true }) throws -> RGBAImage {
        let stride = tile - 2 * pad
        precondition(stride > 0)
        let outW = image.width * scale, outH = image.height * scale
        var out = RGBAImage(width: outW, height: outH, fill: 255)

        var origins: [(Int, Int)] = []
        for y in Swift.stride(from: 0, to: image.height, by: stride) {
            for x in Swift.stride(from: 0, to: image.width, by: stride) { origins.append((x, y)) }
        }

        var controlValues: [String: MLFeatureValue] = [:]
        for name in scalarInputs {
            let a = try MLMultiArray(shape: [1], dataType: .float32)
            a[0] = NSNumber(value: Float(min(max(controls[name] ?? 0.5, 0), 1)))
            controlValues[name] = MLFeatureValue(multiArray: a)
        }

        var buffers: [CVPixelBuffer] = []
        for _ in 0..<min(batchSize, origins.count) { buffers.append(try makeBuffer(tile, tile)) }

        var done = 0
        while done < origins.count {
            let batch = Array(origins[done..<min(done + batchSize, origins.count)])
            var providers: [MLFeatureProvider] = []
            for (i, (x, y)) in batch.enumerated() {
                fill(buffers[i], from: image, originX: x - pad, originY: y - pad)
                var dict: [String: MLFeatureValue] = [inputName: MLFeatureValue(pixelBuffer: buffers[i])]
                dict.merge(controlValues) { $1 }
                providers.append(try MLDictionaryFeatureProvider(dictionary: dict))
            }
            let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
            for (i, (x, y)) in batch.enumerated() {
                guard let pb = results.features(at: i).featureValue(for: outputName)?.imageBufferValue else {
                    throw PixoraError.modelIO("thiếu output \(outputName)")
                }
                let validW = min(stride, image.width - x), validH = min(stride, image.height - y)
                try copyCentre(pb, into: &out, dstX: x * scale, dstY: y * scale, width: validW * scale, height: validH * scale)
            }
            done += batch.count
            if !progress(Double(done) / Double(origins.count)) { throw CancellationError() }
        }
        return out
    }

    private func makeBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let status = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { throw PixoraError.modelIO("CVPixelBufferCreate \(status)") }
        return pb
    }

    /// Writes a tile×tile window of `image` (edge-replicated outside) into a BGRA buffer.
    private func fill(_ pb: CVPixelBuffer, from image: RGBAImage, originX: Int, originY: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let maxX = image.width - 1, maxY = image.height - 1
        image.pixels.withUnsafeBufferPointer { src in
            for ty in 0..<tile {
                let sy = min(max(originY + ty, 0), maxY)
                let srow = sy * image.width * 4
                let drow = base + ty * rb
                for tx in 0..<tile {
                    let sx = min(max(originX + tx, 0), maxX)
                    let s = srow + sx * 4
                    let d = drow + tx * 4
                    d[0] = src[s + 2]; d[1] = src[s + 1]; d[2] = src[s]; d[3] = 255
                }
            }
        }
    }

    private func copyCentre(_ pb: CVPixelBuffer, into out: inout RGBAImage, dstX: Int, dstY: Int, width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        // Byte offsets of R, G, B inside one source pixel.
        let (r, g, b): (Int, Int, Int)
        switch fmt {
        case kCVPixelFormatType_32BGRA: (r, g, b) = (2, 1, 0)
        case kCVPixelFormatType_32ARGB: (r, g, b) = (1, 2, 3)
        case kCVPixelFormatType_32RGBA: (r, g, b) = (0, 1, 2)
        default: throw PixoraError.modelIO("pixel format output không hỗ trợ: \(fmt)")
        }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let off = pad * scale
        let outW = out.width
        out.pixels.withUnsafeMutableBufferPointer { dst in
            for yy in 0..<height {
                let srow = base + (off + yy) * rb + off * 4
                var d = ((dstY + yy) * outW + dstX) * 4
                for xx in 0..<width {
                    let s = srow + xx * 4
                    dst[d] = s[r]; dst[d + 1] = s[g]; dst[d + 2] = s[b]
                    d += 4
                }
            }
        }
    }
}
