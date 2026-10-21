import XCTest
@testable import PixoraCore

final class PixoraCoreTests: XCTestCase {
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
        XCTAssertEqual(out.lastPathComponent, "photo-pixora.jpg")
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
          {"name": "Pixora-0.3.0.dmg", "url": "https://api.github.com/repos/x/y/releases/assets/1", "size": 700},
          {"name": "Pixora-0.3.0.dmg.sha256", "url": "https://api.github.com/repos/x/y/releases/assets/2", "size": 80},
          {"name": "Pixora-Recover-0.3.0-1.zip", "url": "https://api.github.com/repos/x/y/releases/assets/3", "size": 9}]}
        """
        let r = try Updater.parseRelease(Data(json.utf8))
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertEqual(r.dmg?.name, "Pixora-0.3.0.dmg")
        XCTAssertEqual(r.checksum?.name, "Pixora-0.3.0.dmg.sha256")
        XCTAssertNotNil(r.published)
        let old = try Updater.parseRelease(Data(#"{"tag_name": "v0.1.0", "assets": [{"name": "Pixora-0.1.0-macOS-arm64.zip", "url": "https://a/1"}]}"#.utf8))
        XCTAssertNil(old.dmg, "a release without a DMG cannot auto-update")
    }

    /// End-to-end install from a local DMG into a temporary folder:
    /// PIXORA_TEST_DMG=build/Pixora-<v>.dmg swift test --filter testUpdaterInstallsFromDMG
    func testUpdaterInstallsFromDMG() throws {
        guard let path = ProcessInfo.processInfo.environment["PIXORA_TEST_DMG"] else { throw XCTSkip("PIXORA_TEST_DMG not set") }
        let dmg = URL(fileURLWithPath: path)
        XCTAssertThrowsError(try Updater.stage(dmg: dmg, sha256: String(repeating: "0", count: 64), version: APIServer.version))
        let prepared = try Updater.stage(dmg: dmg, sha256: try Updater.sha256(of: dmg), version: APIServer.version)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-install-test")
        try? FileManager.default.removeItem(at: dir)
        let target = dir.appendingPathComponent("Pixora.app")
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
}
