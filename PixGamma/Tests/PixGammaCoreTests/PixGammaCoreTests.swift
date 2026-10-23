import XCTest
@testable import PixGammaCore

final class PixGammaCoreTests: XCTestCase {
    func testOutputSizeKeepsAspect() {
        XCTAssertEqual(OutputSize.factor(2.5).resolve(width: 100, height: 40).0, 250)
        XCTAssertEqual(OutputSize.width(1000).resolve(width: 400, height: 300).1, 750)
        XCTAssertEqual(OutputSize.height(600).resolve(width: 400, height: 300).0, 800)
    }

    func testModeAliases() {
        XCTAssertEqual(EnhanceMode.parse("std"), .standard)
        XCTAssertEqual(EnhanceMode.parse("cgi"), .art)
        XCTAssertEqual(EnhanceMode.parse("low"), .lowres)
        XCTAssertEqual(EnhanceMode.parse("rec"), .recover)
        XCTAssertNil(EnhanceMode.parse("redefine"))
    }

    func testRecoverTilesCoverCanvasWithOverlap() {
        // 1536 px wide → 192 latent columns; tiles of 64 every 48, last one flush.
        XCTAssertEqual(GenerativeRefiner.origins(192), [0, 48, 96, 128])
        XCTAssertEqual(GenerativeRefiner.origins(64), [0])
        let o = GenerativeRefiner.origins(150)
        XCTAssertEqual(o.last! + 64, 150)
        XCTAssertTrue(zip(o, o.dropFirst()).allSatisfy { $1 - $0 <= 48 })
    }

    func testSimilarityRecoversKnownTransform() {
        // Rotate 30°, scale 1.5, translate (10, -4).
        let a = 1.5 * cos(Double.pi / 6), b = 1.5 * sin(Double.pi / 6)
        let src = FaceRestorer.template
        let dst = src.map { SIMD2(a * $0.x - b * $0.y + 10, b * $0.x + a * $0.y - 4) }
        let (ra, rb, tx, ty) = FaceRestorer.similarity(from: src, to: dst)
        XCTAssertEqual(ra, a, accuracy: 1e-9)
        XCTAssertEqual(rb, b, accuracy: 1e-9)
        XCTAssertEqual(tx, 10, accuracy: 1e-6)
        XCTAssertEqual(ty, -4, accuracy: 1e-6)
    }

    func testFaceRestoreKeepsMonochromeChroma() {
        // Sepia ramp (chroma follows brightness) vs. the same ramp with coloured blocks.
        func image(colour: Bool) -> RGBAImage {
            var px = [UInt8](repeating: 255, count: 64 * 64 * 4)
            for y in 0..<64 {
                for x in 0..<64 {
                    let l = Double(x) / 63 * 200 + 30
                    var c = colour && (y / 16) % 2 == 0
                        ? [[220.0, 60, 50], [40, 160, 70], [50, 80, 210], [200, 190, 40]][x / 16]
                        : [l * 1.07, l * 0.98, l * 0.8]
                    c = c.map { min(255, $0 + Double((x * 7 + y * 13) % 5) - 2) }   // scan noise
                    for k in 0..<3 { px[(y * 64 + x) * 4 + k] = UInt8(c[k]) }
                }
            }
            return RGBAImage(width: 64, height: 64, pixels: px)
        }
        XCTAssertGreaterThan(FaceRestorer.monochromeWeight(image(colour: false)), 0.99)
        XCTAssertLessThan(FaceRestorer.monochromeWeight(image(colour: true)), 0.01)

        // Monochrome: a bluish restored eye only brightens/darkens, the sepia tint stays.
        let old = SIMD3(120.0, 110, 90), blue = SIMD3(70.0, 110, 170)
        let m = FaceRestorer.blend(old: old, restored: blue, mono: 1)
        XCTAssertEqual(m.x - m.y, old.x - old.y, accuracy: 1e-9)
        XCTAssertEqual(m.z - m.y, old.z - old.y, accuracy: 1e-9)
        let luma = SIMD3(0.299, 0.587, 0.114)
        XCTAssertEqual((m * luma).sum(), (blue * luma).sum(), accuracy: 1e-9)
        // Colour photos take the restored pixel unchanged.
        XCTAssertEqual(FaceRestorer.blend(old: old, restored: blue, mono: 0), blue)
    }

    func testPreserveColorRemovesTint() {
        let src = RGBAImage(width: 8, height: 8, pixels: [UInt8](repeating: 128, count: 8 * 8 * 4))
        var tinted = src.resized(width: 32, height: 32)
        for i in stride(from: 0, to: tinted.pixels.count, by: 4) { tinted.pixels[i] = 168 } // red cast
        let fixed = Filters.preserveColor(output: tinted, source: src)
        XCTAssertEqual(Int(fixed.pixels[(16 * 32 + 16) * 4]), 128, accuracy: 2)
    }

    func testBatchNamingNeverOverwritesSource() {
        let u = URL(fileURLWithPath: "/tmp/photo.jpg")
        let out = Batch.outputURL(for: u, relative: "photo.jpg", outputDirectory: nil, format: .preserve,
                                  naming: NamingOptions(), modeName: "standard", sizeTag: "4x")
        XCTAssertEqual(out.lastPathComponent, "photo-pixgamma.jpg")
    }

    func testBatchNamingAddsSuffixWhenOutputFolderIsSourceFolder() {
        let u = URL(fileURLWithPath: "/tmp/photo.jpg")
        let same = Batch.outputURL(for: u, relative: "photo.jpg", outputDirectory: URL(fileURLWithPath: "/tmp/"), format: .preserve,
                                   naming: NamingOptions(), modeName: "standard", sizeTag: "4x")
        XCTAssertEqual(same.lastPathComponent, "photo-pixgamma.jpg")
        let other = Batch.outputURL(for: u, relative: "photo.jpg", outputDirectory: URL(fileURLWithPath: "/tmp/out"), format: .preserve,
                                    naming: NamingOptions(), modeName: "standard", sizeTag: "4x")
        XCTAssertEqual(other.lastPathComponent, "photo.jpg")
        let converted = Batch.outputURL(for: u, relative: "photo.jpg", outputDirectory: URL(fileURLWithPath: "/tmp"), format: .png,
                                        naming: NamingOptions(), modeName: "standard", sizeTag: "4x")
        XCTAssertEqual(converted.lastPathComponent, "photo.png")
    }

    func testHTTPRequestWaitsForFullBody() {
        let head = "POST /v1/upscale?scale=2&mode=art HTTP/1.1\r\nContent-Length: 4\r\n\r\n"
        XCTAssertNil(Request.parse(Data((head + "ab").utf8)))
        let req = Request.parse(Data((head + "abcd").utf8))
        XCTAssertEqual(req?.query["scale"], "2")
        XCTAssertEqual(req?.body.count, 4)
    }

    func testDihedralInverseRestoresImage() {
        var img = RGBAImage(width: 5, height: 3)
        for i in img.pixels.indices { img.pixels[i] = UInt8(i % 251) }
        for k in 0..<8 {
            let t = img.dihedral(k)
            XCTAssertEqual(t.width, k & 4 != 0 ? 3 : 5)
            XCTAssertEqual(t.dihedral(k, inverse: true).pixels, img.pixels, "k=\(k)")
        }
        // Transpose: pixel (x: 1, y: 0) moves to (x: 0, y: 1).
        XCTAssertEqual(img.dihedral(4).pixels[(1 * 3 + 0) * 4], img.pixels[(0 * 5 + 1) * 4])
    }

    func testUpdaterVersionOrder() {
        XCTAssertTrue(Updater.isNewer("v0.2.1", than: "0.2.0"))
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(Updater.isNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.2.0-beta", than: "0.2.0"))
    }

    func testUpdaterReadsRelease() throws {
        let json = """
        {"tag_name": "v0.3.0", "body": "Ghi chú", "published_at": "2026-10-20T01:00:00Z", "assets": [
          {"name": "PixGamma-0.3.0.dmg", "url": "https://api.github.com/repos/x/y/releases/assets/1", "size": 700},
          {"name": "PixGamma-0.3.0.dmg.sha256", "url": "https://api.github.com/repos/x/y/releases/assets/2", "size": 80},
          {"name": "PixGamma-Recover-0.3.0-1.zip", "url": "https://api.github.com/repos/x/y/releases/assets/3", "size": 9}]}
        """
        let r = try Updater.parseRelease(Data(json.utf8))
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertEqual(r.dmg?.name, "PixGamma-0.3.0.dmg")
        XCTAssertEqual(r.checksum?.name, "PixGamma-0.3.0.dmg.sha256")
        XCTAssertNotNil(r.published)
        let old = try Updater.parseRelease(Data(#"{"tag_name": "v0.1.0", "assets": [{"name": "PixGamma-0.1.0-macOS-arm64.zip", "url": "https://a/1"}]}"#.utf8))
        XCTAssertNil(old.dmg, "a release without a DMG cannot auto-update")
    }

    func testUpdaterHandlesPixoraRename() throws {
        // Both installers in one release: the new name wins.
        let both = """
        {"tag_name": "v0.3.0", "assets": [
          {"name": "Pixora-0.3.0.dmg", "url": "https://a/1"}, {"name": "Pixora-0.3.0.dmg.sha256", "url": "https://a/2"},
          {"name": "PixGamma-0.3.0.dmg", "url": "https://a/3"}, {"name": "PixGamma-0.3.0.dmg.sha256", "url": "https://a/4"}]}
        """
        XCTAssertEqual(try Updater.parseRelease(Data(both.utf8)).dmg?.name, "PixGamma-0.3.0.dmg")
        let legacy = try Updater.parseRelease(Data(#"{"tag_name": "v0.2.1", "assets": [{"name": "Pixora-0.2.1.dmg", "url": "https://a/1"}, {"name": "Pixora-0.2.1.dmg.sha256", "url": "https://a/2"}]}"#.utf8))
        XCTAssertEqual(legacy.dmg?.name, "Pixora-0.2.1.dmg")
        XCTAssertEqual(legacy.checksum?.name, "Pixora-0.2.1.dmg.sha256")

        let apps = URL(fileURLWithPath: "/Applications")
        XCTAssertEqual(Updater.PreparedUpdate.destination(replacing: apps.appendingPathComponent("Pixora.app")).lastPathComponent, "PixGamma.app")
        XCTAssertEqual(Updater.PreparedUpdate.destination(replacing: apps.appendingPathComponent("PixGamma.app")).lastPathComponent, "PixGamma.app")
        XCTAssertEqual(Updater.PreparedUpdate.destination(replacing: URL(fileURLWithPath: "/tmp/Test.app")).path, "/tmp/Test.app")
    }

    func testUpdaterTokenIsOptional() throws {
        let url = URL(string: "https://api.github.com/repos/x/y/releases/latest")!
        XCTAssertNil(Updater.request(url, accept: "a", token: nil).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(Updater.request(url, accept: "a", token: "").value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(Updater.request(url, accept: "a", token: "t").value(forHTTPHeaderField: "Authorization"), "Bearer t")

        func status(_ code: Int, _ headers: [String: String] = [:]) throws {
            try Updater.check(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers))
        }
        XCTAssertNoThrow(try status(200))
        let limited = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"]
        for code in [403, 429] {
            XCTAssertThrowsError(try status(code, limited)) { e in
                guard case Updater.UpdateError.rateLimited(let reset) = e else { return XCTFail("\(e)") }
                XCTAssertEqual(reset, Date(timeIntervalSince1970: 1_800_000_000))
            }
        }
        XCTAssertThrowsError(try status(403, ["x-ratelimit-remaining": "12"])) { e in
            guard case Updater.UpdateError.network = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try status(401)) { e in
            guard case Updater.UpdateError.unauthorized = e else { return XCTFail("\(e)") }
        }
    }

    /// End-to-end install from a local DMG into a temporary folder:
    /// PIXGAMMA_TEST_DMG=build/PixGamma-<v>.dmg swift test --filter testUpdaterInstallsFromDMG
    func testUpdaterInstallsFromDMG() throws {
        guard let path = ProcessInfo.processInfo.environment["PIXGAMMA_TEST_DMG"] else { throw XCTSkip("PIXGAMMA_TEST_DMG not set") }
        let dmg = URL(fileURLWithPath: path)
        XCTAssertThrowsError(try Updater.stage(dmg: dmg, sha256: String(repeating: "0", count: 64), version: APIServer.version))
        let prepared = try Updater.stage(dmg: dmg, sha256: try Updater.sha256(of: dmg), version: APIServer.version)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixgamma-install-test")
        try? FileManager.default.removeItem(at: dir)
        let target = dir.appendingPathComponent("PixGamma.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        try prepared.relaunch(replacing: target, pid: 999_999, reopen: false)  // no such pid: replaces at once
        let deadline = Date().addingTimeInterval(60)
        while FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/marker").path) || !FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path) {
            XCTAssertLessThan(Date(), deadline, "install did not finish"); if Date() > deadline { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
        let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, APIServer.version)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".old"))
    }

    func testSceneDescriberNamesSubjectAndTexture() {
        let parrot = SceneDescriber.prompt(labels: [("animal", 0.96), ("bird", 0.96), ("parrot", 0.96)])
        XCTAssertEqual(parrot, "high quality photograph of a parrot, detailed feathers with fine barbs and shafts, sharp focus, natural light")
        // A printed T-shirt: fabric first, and low-confidence scenery labels are ignored.
        let shirt = SceneDescriber.prompt(labels: [("people", 0.84), ("clothing", 0.52), ("structure", 0.45), ("rocks", 0.26)])
        XCTAssertEqual(shirt?.hasPrefix("high quality photograph of a garment, fine fabric weave"), true)
        XCTAssertFalse(shirt?.contains("stone") ?? true)
        XCTAssertNil(SceneDescriber.prompt(labels: [("sign", 0.2)]))
        // Safety kinds: a sign behind people is graphic; leather at low confidence is a product.
        XCTAssertEqual(SceneDescriber.kind(labels: [("people", 0.84), ("sign", 0.43)]), .graphic)
        XCTAssertEqual(SceneDescriber.kind(labels: [("material", 0.15), ("textile", 0.15)]), .product)
        XCTAssertEqual(SceneDescriber.kind(labels: [("bird", 0.96)]), .organic)
        // Two lines with a skipped line between them merge into one protected block.
        let blocks = Upscaler.textBlocks([CGRect(x: 10, y: 10, width: 100, height: 8), CGRect(x: 10, y: 34, width: 100, height: 8)],
                                         width: 200, height: 200)
        XCTAssertEqual(blocks.count, 1)
    }
}
