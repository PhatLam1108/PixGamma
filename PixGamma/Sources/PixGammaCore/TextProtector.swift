import CoreGraphics
import Foundation
import Vision

/// Keeps printed text (keyboard legends, labels, screens, signs) legible.
///
/// GAN upscalers invent texture and tend to melt small glyphs. PixGamma finds text with
/// Vision and, inside those regions only, swaps in the output of the faithful network
/// (High Fidelity with detail = 0, i.e. RealESRNet), feathered into the main result.
enum TextProtector {
    /// Languages for recognition. Vietnamese needs the accurate recogniser (diacritics such as
    /// ả, ơ, ữ sit above and below the line, so boxes must cover them).
    static let languages = ["vi-VT", "en-US"]

    struct Detection {
        var regions: [CGRect]      // source pixels, padded and merged
        var lineBoxes: [CGRect]    // unpadded text lines/words, source pixels (sets the size gate)
        var lines: [String]        // recognised text, top to bottom
    }

    /// Text regions in source pixel coordinates (top-left origin), padded and merged.
    static func detect(_ image: RGBAImage) -> [CGRect] { analyze(image).regions }

    /// Detection on the source plus on the network's output (where small, blurry text is far
    /// easier for Vision to find), in source coordinates.
    static func analyze(source: RGBAImage, upscaled: RGBAImage) -> Detection {
        var det = analyze(source)
        let cap = 2400.0
        let f = min(1, cap / Double(max(upscaled.width, upscaled.height)))
        let probe = f < 1 ? upscaled.resized(width: Int(Double(upscaled.width) * f), height: Int(Double(upscaled.height) * f)) : upscaled
        let up = analyze(probe)
        let sx = Double(source.width) / Double(probe.width), sy = Double(source.height) / Double(probe.height)
        let mapped = up.regions.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy).integral }
        det.regions = merge(det.regions + mapped)
        det.lineBoxes += up.lineBoxes.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
        if up.lines.count > det.lines.count { det.lines = up.lines }
        // Vision often stops a few words short on small print; the rest of the line would keep
        // the photo network's blocky output, so regions follow the ink to the end of the line.
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        det.regions = merge(det.regions.map { extendAlongInk($0, source).intersection(bounds) })
        return det
    }

    /// Grows `r` left and right while columns in its rows still hold text-like contrast
    /// (gaps up to one line height, the space between words).
    static func extendAlongInk(_ r: CGRect, _ src: RGBAImage) -> CGRect {
        let y0 = max(0, Int(r.minY)), y1 = min(src.height, Int(r.maxY.rounded(.up)))
        let x0 = max(0, Int(r.minX)), x1 = min(src.width, Int(r.maxX.rounded(.up)))
        guard y1 - y0 >= 3, x1 > x0, r.height < 0.25 * Double(src.height) else { return r }
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = (y * src.width + x) * 4
            return 0.299 * Double(src.pixels[p]) + 0.587 * Double(src.pixels[p + 1]) + 0.114 * Double(src.pixels[p + 2])
        }
        // Contrast of a column: max |luma − median of the region|.
        var vals: [Double] = []
        for y in y0..<y1 { for x in x0..<x1 { vals.append(luma(x, y)) } }
        let bg = vals.sorted()[vals.count / 2]
        let peak = vals.map { abs($0 - bg) }.max() ?? 0
        guard peak > 20 else { return r }
        func inked(_ x: Int) -> Bool { (y0..<y1).contains { abs(luma(x, $0) - bg) > 0.45 * peak } }
        let maxGap = max(3, Int(r.height * 0.6))
        var right = x1, gap = 0, x = x1
        while x < src.width, gap <= maxGap {
            if inked(x) { right = x + 1; gap = 0 } else { gap += 1 }
            x += 1
        }
        var left = x0
        gap = 0; x = x0 - 1
        while x >= 0, gap <= maxGap {
            if inked(x) { left = x; gap = 0 } else { gap += 1 }
            x -= 1
        }
        let pad = r.height * 0.2
        return CGRect(x: Double(left) - (left < x0 ? pad : 0), y: r.minY,
                      width: Double(right - left) + (left < x0 ? pad : 0) + (right > x1 ? pad : 0), height: r.height)
    }

    /// Finds text on the source and on a 2× enlarged copy (small legends and captions that
    /// Vision misses at native size are found once they are bigger), and reads it.
    static func analyze(_ image: RGBAImage) -> Detection {
        var boxes: [CGRect] = []
        var lineBoxes: [CGRect] = []
        var lines: [(box: CGRect, text: String, conf: Float)] = []
        let W = Double(image.width), H = Double(image.height)
        let passes: [(RGBAImage, Double)] = max(image.width, image.height) <= 2400
            ? [(image, 1), (image.resized(width: image.width * 2, height: image.height * 2), 2)]
            : [(image, 1)]
        for (img, _) in passes {
            guard let cg = img.makeCGImage() else { continue }
            let rects = VNDetectTextRectanglesRequest()
            rects.reportCharacterBoxes = true
            let recognize = VNRecognizeTextRequest()
            recognize.recognitionLevel = .accurate
            recognize.recognitionLanguages = languages
            recognize.usesLanguageCorrection = true
            recognize.minimumTextHeight = 0.003
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([rects, recognize])

            func add(_ b: CGRect) {
                // Vision is normalised with a bottom-left origin; map to source pixels.
                boxes.append(CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H))
            }
            func toPixels(_ b: CGRect) -> CGRect { CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H) }
            for obs in rects.results ?? [] {
                lineBoxes.append(toPixels(obs.boundingBox))
                if let chars = obs.characterBoxes, !chars.isEmpty { chars.forEach { add($0.boundingBox) } } else { add(obs.boundingBox) }
            }
            for obs in recognize.results ?? [] {
                guard let top = obs.topCandidates(1).first, top.confidence > 0.3 else { continue }
                add(obs.boundingBox)
                lineBoxes.append(toPixels(obs.boundingBox))
                // Both passes read the same line: keep the more confident reading.
                let b = obs.boundingBox
                if let i = lines.firstIndex(where: { l in
                    let inter = l.box.intersection(b)
                    return !inter.isNull && inter.width * inter.height > 0.5 * min(l.box.width * l.box.height, b.width * b.height)
                }) {
                    if top.confidence > lines[i].conf { lines[i] = (b, top.string, top.confidence) }
                } else {
                    lines.append((b, top.string, top.confidence))
                }
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        // Generous vertical padding keeps Vietnamese tone marks and hooks inside the region.
        let padded = boxes.map { $0.insetBy(dx: -max(4, $0.height * 0.4), dy: -max(4, $0.height * 0.55)).intersection(bounds) }
            .filter { !$0.isNull && $0.width >= 3 && $0.height >= 3 }
        // Only true duplicates are merged (the two passes, character vs line boxes). Fusing
        // every touching box turned text-heavy banners into one frame-sized block, which the
        // size cap then dropped, so no text was protected at all. The cap now applies to single
        // boxes: one box covering much of the frame is a false detection.
        let area = W * H
        let regions = merge(padded.filter { Double($0.width * $0.height) < 0.2 * area })
        return Detection(regions: regions, lineBoxes: lineBoxes.filter { $0.height >= 2 && Double($0.width * $0.height) < 0.2 * area },
                         lines: lines.sorted { $0.box.midY > $1.box.midY }.map(\.text))
    }

    /// Union of rectangles that substantially overlap (duplicates of the same text).
    static func merge(_ rects: [CGRect]) -> [CGRect] {
        var out = rects
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < out.count {
                var j = i + 1
                while j < out.count {
                    let inter = out[i].intersection(out[j])
                    let smaller = min(out[i].width * out[i].height, out[j].width * out[j].height)
                    if !inter.isNull && inter.width * inter.height > 0.3 * smaller {
                        out[i] = out[i].union(out[j])
                        out.remove(at: j)
                        changed = true
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }
        return out.map { $0.integral }
    }

    /// How much of the Text model to use for a line whose ink spread (`inkSpread`) is `spread`
    /// source pixels. Text v3 with the 8-way ensemble reads as well as bicubic down to 4.3 px
    /// capitals and is far sharper; at 3.6 px capitals (spread ≈ 1.0) a tone mark is under a
    /// pixel and the network draws crisp but wrong letters, so such lines fade to the plain
    /// resample: softer, but never a different letter. Re-typesetting them from Vision's reading
    /// was tried and rejected: wrong readings fit the pixels as well as right ones.
    static func modelWeight(spread: Double) -> Double {
        let lo = 1.15, hi = 1.22
        let t = min(1, max(0, (spread - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }

    /// Vertical spread (standard deviation, source pixels) of the ink in a text line: about a
    /// quarter of the capital height, measured to a fraction of a pixel. Vision's boxes are a
    /// pixel or two off on text this small (a 3.6 px line can get a taller box than a 4.3 px
    /// one), the ink itself is not.
    static func inkSpread(_ src: RGBAImage, _ box: CGRect) -> Double {
        let h = Double(box.height)
        let x0 = max(0, Int(box.minX)), x1 = min(src.width, Int(box.maxX.rounded(.up)))
        let y0 = max(0, Int(Double(box.minY) - 0.3 * h)), y1 = min(src.height, Int((Double(box.maxY) + 0.3 * h).rounded(.up)))
        guard x1 - x0 >= 4, y1 - y0 >= 3 else { return 0 }
        var luma = [Double](), w = x1 - x0
        for y in y0..<y1 { for x in x0..<x1 {
            let p = (y * src.width + x) * 4
            luma.append(0.299 * Double(src.pixels[p]) + 0.587 * Double(src.pixels[p + 1]) + 0.114 * Double(src.pixels[p + 2]))
        } }
        let bg = luma.sorted()[luma.count / 2]
        let d = luma.map { abs($0 - bg) }
        let floor = 0.1 * (d.max() ?? 0)
        var rows = [Double](repeating: 0, count: y1 - y0)
        for (i, v) in d.enumerated() { rows[i / w] += max(0, v - floor) }
        let total = rows.reduce(0, +)
        guard total > 0 else { return 0 }
        let mean = rows.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / total
        let varc = rows.enumerated().reduce(0) { $0 + (Double($1.offset) - mean) * (Double($1.offset) - mean) * $1.element } / total
        return varc.squareRoot()
    }

    /// Ink contrast over background noise in a text line: 99th percentile of |luma − median|
    /// over the noise, the residual against a 3×3 median in the flattest quarter of half-line
    /// blocks (edges of the sign or keycap around the text would otherwise count as noise).
    /// Clean print, screens, keycaps and transit signs score 30–260; small body text
    /// photographed on a grainy sign scores 10–19, and there every network turns the strokes
    /// into letter-like gibberish.
    static func inkSNR(_ src: RGBAImage, _ box: CGRect) -> Double {
        // Widened by a line height: Vision boxes a keycap letter tightly, leaving no flat ground
        // to measure the noise on (the stroke edges then counted as noise).
        let h = Double(box.height)
        let x0 = max(0, Int(Double(box.minX) - h)), x1 = min(src.width, Int((Double(box.maxX) + h).rounded(.up)))
        let y0 = max(0, Int(Double(box.minY) - 0.5 * h)), y1 = min(src.height, Int((Double(box.maxY) + 0.5 * h).rounded(.up)))
        let w = x1 - x0, hh = y1 - y0
        guard w >= 4, hh >= 4 else { return 0 }
        var luma = [Double](repeating: 0, count: w * hh)
        for y in 0..<hh { for x in 0..<w {
            let p = ((y0 + y) * src.width + x0 + x) * 4
            luma[y * w + x] = 0.299 * Double(src.pixels[p]) + 0.587 * Double(src.pixels[p + 1]) + 0.114 * Double(src.pixels[p + 2])
        } }
        let bg = luma.sorted()[luma.count / 2]
        let d = luma.map { abs($0 - bg) }.sorted()
        let peak = d[min(d.count - 1, Int(0.99 * Double(d.count)))]
        guard peak > 0 else { return 0 }
        var res = [Double](repeating: 0, count: w * hh)
        for y in 0..<hh { for x in 0..<w {
            var n: [Double] = []
            for dy in -1...1 { for dx in -1...1 { n.append(luma[min(hh - 1, max(0, y + dy)) * w + min(w - 1, max(0, x + dx))]) } }
            res[y * w + x] = abs(luma[y * w + x] - n.sorted()[4])
        } }
        let b = max(3, Int(h / 2 + 0.5))
        var blocks: [Double] = []
        var by = 0
        while by + b <= hh {
            var bx = 0
            while bx + b <= w {
                var v: [Double] = []
                for y in by..<(by + b) { for x in bx..<(bx + b) { v.append(res[y * w + x]) } }
                blocks.append(v.sorted()[v.count / 2])
                bx += b
            }
            by += b
        }
        guard !blocks.isEmpty else { return peak / 0.5 }
        return peak / (1.48 * blocks.sorted()[blocks.count / 4] + 0.5)
    }

    /// How much of the network to use for a line `height` source pixels tall (Vision's box)
    /// with ink SNR `snr`. Lines 13 px and up are always the network's; smaller lines need clean
    /// ink (SNR ≥ 32), otherwise they fade to the plain resample: blurry, but the letters it
    /// shows are the ones in the photo.
    static func cleanWeight(height: Double, snr: Double) -> Double {
        func step(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            let t = min(1, max(0, (v - lo) / (hi - lo)))
            return t * t * (3 - 2 * t)
        }
        return max(step(height, 10, 13), step(snr, 22, 32))
    }

    /// Re-renders text regions with the faithful network and feathers them into `output`.
    static func protect(output: inout RGBAImage, source: RGBAImage, regions: [CGRect], lineBoxes: [CGRect] = [], device: ComputeDevice,
                        progress: (Double) -> Bool) throws -> Int {
        let spec = ModelCatalog.text
        guard !regions.isEmpty, ModelStore.shared.isAvailable(spec.file) else { return 0 }
        let engine = try TileEngine(model: ModelStore.shared.model(spec.file, device: device), spec: spec)
        // PixGamma Photo v1 reads right even on 3.6 px capitals (OCR 76.1 % vs 72.3 % for the plain
        // resample), so only the older Text model needs the small-text fade.
        // Self-ensemble size. With Photo v1, 2 passes (as is + 180° turn) read best (OCR 91.1 %
        // vs 90.4 % for 8) at a third of the time (keyboard 480 px at 4x: 12 s vs 37 s); the
        // RealPLKSR Text model is fast enough for all 8. PIXGAMMA_TEXT_TTA=1|2|4|8 overrides.
        let passes = Int(Env.get("TEXT_TTA") ?? "") ?? (spec.file == "PhotoV1" ? 2 : 8)
        let sizeWeight: (Double) -> Double = spec.file == "PhotoV1" ? { _ in 1 } : { modelWeight(spread: $0) }
        let debug = Env.isSet("DEBUG_TEXT")
        let sx = Double(output.width) / Double(source.width), sy = Double(output.height) / Double(source.height)
        let feather = max(2.0, 1.5 * sx)

        for (n, r) in regions.enumerated() {
            let x = Int(r.minX), y = Int(r.minY), w = Int(r.width), h = Int(r.height)
            // Run with real surrounding pixels as context, then cut the region back out.
            let ctx = 16
            let cx = max(0, x - ctx), cy = max(0, y - ctx)
            let cw = min(source.width, x + w + ctx) - cx, ch = min(source.height, y + h + ctx) - cy
            let crop = source.cropped(x: cx, y: cy, width: cw, height: ch)
            // Per-pixel model weight from the lines inside this region (a banner block mixes a
            // big title with tiny small print). Pixels outside any line take the region's
            // smallest line, padding included, so marks above small letters stay faithful.
            let inside = lineBoxes.filter { $0.intersects(r) }
            // The passes box the same line slightly differently: use the median spread over
            // the boxes on that line.
            let spreads = inside.map { inkSpread(source, $0) }
            let snrs = inside.map { inkSNR(source, $0) }
            let median: ([Double], Int) -> Double = { vals, k in
                let b = inside[k]
                let same = inside.indices.filter { abs(inside[$0].midY - b.midY) < 0.35 * max(inside[$0].height, b.height)
                    && inside[$0].minX < b.maxX && b.minX < inside[$0].maxX }
                let v = same.map { vals[$0] }.sorted()
                return v[v.count / 2]
            }
            let heights = inside.map { Double($0.height) }
            // Only lines of a paragraph fade (word-shaped, with another line of about the same size
            // just above or below): Vision's stray boxes on leaves, foil rims and facades are
            // low-SNR too, and fading them left soft patches in the texture.
            func inParagraph(_ b: CGRect) -> Bool {
                b.width >= 2.5 * b.height && lineBoxes.contains { o in
                    let r = o.height / b.height, dy = abs(o.midY - b.midY)
                    return r > 0.7 && r < 1.4 && dy > 0.6 * b.height && dy < 2.5 * b.height && o.minX < b.maxX && b.minX < o.maxX
                }
            }
            let lineWeight = inside.indices.map { k in
                sizeWeight(median(spreads, k)) * (inParagraph(inside[k]) ? cleanWeight(height: median(heights, k), snr: median(snrs, k)) : 1)
            }
            if debug {
                let s = zip(inside, lineWeight).enumerated().map { k, e in
                    String(format: "%.0f,%.0f:%.0fx%.1f snr %.1f w %.2f", e.0.minX, e.0.minY, e.0.width, e.0.height, snrs[k], e.1)
                }.joined(separator: "; ")
                FileHandle.standardError.write(Data("TEXT_WEIGHT \(x),\(y),\(w),\(h) \(s)\n".utf8))
            }
            // The noise fade stays on the lines themselves: the region reaches along the row to
            // the frame edge on grainy signs, and fading all of it blurred trees and photos.
            let wMin = inside.indices.map { sizeWeight(median(spreads, $0)) }.min() ?? 1
            var wMap = [Double](repeating: wMin, count: w * h)
            for (b, wb) in zip(inside, lineWeight).sorted(by: { $0.1 > $1.1 }) { // lower weights paint last and win
                let pad = b.height * 0.35
                let x0 = max(0, Int(b.minX - pad) - x), x1 = min(w, Int(b.maxX + pad) - x)
                let y0 = max(0, Int(b.minY - pad) - y), y1 = min(h, Int(b.maxY + pad) - y)
                guard x0 < x1, y0 < y1 else { continue }
                for yy in y0..<y1 { for xx in x0..<x1 { wMap[yy * w + xx] = wb } }
            }
            wMap = smooth(wMap, width: w, height: h, radius: 2)
            let useModel = wMap.contains { $0 > 0.01 }
            var faithful = crop
            if useModel {
                var stacked = 1.0
                repeat { // stack passes for > 4x requests
                    // First pass: average over flips/rotations (`passes`). Thin strokes come out
                    // with a slightly different wobble in each orientation; the mean is
                    // straighter and reads better (OCR 88.9 → 90.3 %, PSNR +0.5 dB).
                    faithful = stacked == 1 ? try ensemble(engine, faithful, passes: passes) : try engine.run(faithful)
                    stacked *= Double(spec.scale)
                } while stacked < max(sx, sy) - 0.001
            }
            let ox = Int((Double(x) * sx).rounded()), oy = Int((Double(y) * sy).rounded())
            let ow = min(output.width - ox, Int((Double(w) * sx).rounded())), oh = min(output.height - oy, Int((Double(h) * sy).rounded()))
            guard ow > 0, oh > 0 else { continue }
            // Scale the context crop to output scale, then take the region.
            let fw = Int((Double(cw) * sx).rounded()), fh = Int((Double(ch) * sy).rounded())
            faithful = faithful.resized(width: fw, height: fh)
            let plain = wMap.contains { $0 < 0.99 } ? crop.resized(width: fw, height: fh) : nil
            let offX = min(fw - ow, max(0, ox - Int((Double(cx) * sx).rounded())))
            let offY = min(fh - oh, max(0, oy - Int((Double(cy) * sy).rounded())))
            faithful = faithful.cropped(x: offX, y: offY, width: ow, height: oh)
            let plainCrop = plain?.cropped(x: offX, y: offY, width: ow, height: oh)

            let outW = output.width
            let pl = plainCrop?.pixels ?? faithful.pixels
            faithful.pixels.withUnsafeBufferPointer { f in
                output.pixels.withUnsafeMutableBufferPointer { o in
                    for yy in 0..<oh {
                        let wy = min(h - 1, Int(Double(yy) / sy))
                        for xx in 0..<ow {
                            let edge = Double(min(xx, yy, ow - 1 - xx, oh - 1 - yy))
                            let a = min(1, edge / feather)
                            let wm = wMap[wy * w + min(w - 1, Int(Double(xx) / sx))]
                            let p = ((oy + yy) * outW + ox + xx) * 4, q = (yy * ow + xx) * 4
                            for c in 0..<3 {
                                let v = Double(f[q + c]) * wm + Double(pl[q + c]) * (1 - wm)
                                o[p + c] = UInt8((Double(o[p + c]) * (1 - a) + v * a).rounded())
                            }
                        }
                    }
                }
            }
            if !progress(Double(n + 1) / Double(regions.count)) { throw CancellationError() }
        }
        return regions.count
    }

    /// Mean of the network's output over the 8 symmetries of the square (self-ensemble).
    static func ensemble(_ engine: TileEngine, _ image: RGBAImage, passes: Int = 8) throws -> RGBAImage {
        // 1: as is, 2: + 180° turn, 4: + both flips, 8: + transposes.
        let ks = [[0], [0, 3], [0, 1, 2, 3], Array(0..<8)][[1, 2, 4, 8].firstIndex(of: passes) ?? 3]
        var acc: [Float] = []
        var out = image
        for k in ks {
            let o = try engine.run(image.dihedral(k)).dihedral(k, inverse: true)
            if acc.isEmpty { acc = [Float](repeating: 0, count: o.pixels.count); out = o }
            for i in acc.indices { acc[i] += Float(o.pixels[i]) }
        }
        let n = Float(ks.count)
        for i in acc.indices { out.pixels[i] = UInt8(min(255, max(0, (acc[i] / n).rounded()))) }
        return out
    }

    /// Two box-blur passes over a single-channel map.
    static func smooth(_ m: [Double], width w: Int, height h: Int, radius r: Int) -> [Double] {
        var a = m, b = m
        for _ in 0..<2 {
            for y in 0..<h {
                for x in 0..<w {
                    var s = 0.0, n = 0.0
                    for k in max(0, x - r)...min(w - 1, x + r) { s += a[y * w + k]; n += 1 }
                    b[y * w + x] = s / n
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var s = 0.0, n = 0.0
                    for k in max(0, y - r)...min(h - 1, y + r) { s += b[k * w + x]; n += 1 }
                    a[y * w + x] = s / n
                }
            }
        }
        return a
    }
}
