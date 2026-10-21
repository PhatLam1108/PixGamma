import CryptoKit
import Foundation
import Security

/// Self-update from the GitHub releases of the (private) Pixora repository.
///
/// The repo is private, so reading releases needs a token: the user pastes a fine-grained,
/// read-only token once and it is kept in the login Keychain. A release must carry
/// `Pixora-<version>.dmg` and `Pixora-<version>.dmg.sha256` (made by scripts/make_dmg.sh);
/// the download is only installed when its SHA-256 matches and the app inside reports the
/// release's version and Pixora's bundle id.
public enum Updater {
    public static let repository = "PhatLam1108/Pixora"
    public static let bundleID = "vn.phatlam.pixora"
    public static let tokenHelpURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    public struct Release: Sendable, Equatable {
        public var version: String
        public var notes: String
        public var published: Date?
        public var dmg: Asset?          // nil: release without an installer (cannot auto-update)
        public var checksum: Asset?
    }

    public struct Asset: Sendable, Equatable {
        public var name: String
        public var apiURL: URL
        public var size: Int
    }

    public enum UpdateError: LocalizedError {
        case noToken, unauthorized, notFound, network(String), noInstaller(String), checksum, badBundle(String), notWritable(String)
        public var errorDescription: String? {
            switch self {
            case .noToken: return "Chưa có token GitHub."
            case .unauthorized: return "Token không hợp lệ hoặc đã hết hạn."
            case .notFound: return "Token không đọc được repo Pixora (cần quyền Contents: Read-only cho repo này), hoặc repo chưa có bản phát hành."
            case .network(let m): return "Không kết nối được GitHub: \(m)"
            case .noInstaller(let v): return "Bản \(v) chưa có file cài đặt .dmg."
            case .checksum: return "File tải về không khớp mã SHA-256, đã huỷ cài đặt."
            case .badBundle(let m): return "File cài đặt không hợp lệ: \(m)"
            case .notWritable(let p): return "Không ghi được vào \(p). Hãy kéo Pixora vào Applications bằng tay từ file DMG."
            }
        }
    }

    // MARK: Versions

    /// Numeric parts of "v0.2.0" / "0.2.0-beta" → [0, 2, 0].
    public static func parts(_ v: String) -> [Int] {
        let core = v.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        return core.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Token (Keychain)

    private static let service = "vn.phatlam.pixora.github"

    /// `PIXORA_GITHUB_TOKEN` (not stored) wins over the Keychain, for scripts and CI.
    public static var token: String? {
        if let env = ProcessInfo.processInfo.environment["PIXORA_GITHUB_TOKEN"], !env.isEmpty { return env }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "token", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func setToken(_ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "token"]
        SecItemDelete(base as CFDictionary)
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: GitHub

    static func request(_ url: URL, accept: String, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Pixora/\(APIServer.version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Latest published (non-draft, non-prerelease) release.
    public static func latest(token: String? = Updater.token) async throws -> Release {
        guard let token else { throw UpdateError.noToken }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: request(url, accept: "application/vnd.github+json", token: token)) }
        catch { throw UpdateError.network(error.localizedDescription) }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw UpdateError.unauthorized
        case 403, 404: throw UpdateError.notFound
        case let c: throw UpdateError.network("HTTP \(c)")
        }
        return try parseRelease(data)
    }

    public static func parseRelease(_ data: Data) throws -> Release {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { throw UpdateError.network("phản hồi không đọc được") }
        let version = String(tag.drop { $0 == "v" || $0 == "V" })
        let assets: [Asset] = (j["assets"] as? [[String: Any]] ?? []).compactMap { a in
            guard let n = a["name"] as? String, let u = (a["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Asset(name: n, apiURL: u, size: a["size"] as? Int ?? 0)
        }
        let dmg = assets.first { $0.name.hasPrefix("Pixora-") && $0.name.hasSuffix(".dmg") }
        let published = (j["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: version, notes: j["body"] as? String ?? "", published: published,
                       dmg: dmg, checksum: dmg.flatMap { d in assets.first { $0.name == d.name + ".sha256" } })
    }

    // MARK: Download

    /// Asset downloads redirect to a signed storage URL that rejects the GitHub token,
    /// so the Authorization header is dropped on redirect.
    private final class Delegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                        newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var req = newRequest
            if req.url?.host != "api.github.com" { req.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(req)
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns: move it somewhere we own first.
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw UpdateError.network("HTTP \(code)") }
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume(returning: dest)
            } catch { continuation?.resume(throwing: error) }
            continuation = nil
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation?.resume(throwing: UpdateError.network(error.localizedDescription)); continuation = nil }
        }
    }

    static func download(_ asset: Asset, token: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            delegate.continuation = c
            session.downloadTask(with: request(asset.apiURL, accept: "application/octet-stream", token: token)).resume()
        }
    }

    public static func sha256(of file: URL) throws -> String {
        let h = FileHandle(forReadingAtPath: file.path)
        guard let h else { throw UpdateError.badBundle("không đọc được file tải về") }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Install

    /// Downloads and verifies the DMG, copies the new Pixora.app out of it and returns a
    /// prepared installer; `relaunch` replaces `target` once this process has quit.
    public static func prepare(_ r: Release, token: String? = Updater.token,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate {
        guard let token else { throw UpdateError.noToken }
        guard let dmgAsset = r.dmg else { throw UpdateError.noInstaller(r.version) }
        guard let sumAsset = r.checksum else { throw UpdateError.badBundle("thiếu file \(dmgAsset.name).sha256") }
        let dmg = try await download(dmgAsset, token: token) { progress(0.9 * $0) }
        defer { try? FileManager.default.removeItem(at: dmg) }
        let sumFile = try await download(sumAsset, token: token) { _ in }
        defer { try? FileManager.default.removeItem(at: sumFile) }
        let expected = (try String(contentsOf: sumFile, encoding: .utf8)).split(whereSeparator: \.isWhitespace).first.map(String.init)
        let staged = try stage(dmg: dmg, sha256: expected ?? "", version: r.version)
        progress(1)
        return staged
    }

    /// Verifies a downloaded installer and copies its Pixora.app to a private folder.
    public static func stage(dmg: URL, sha256 expected: String, version: String) throws -> PreparedUpdate {
        guard try sha256(of: dmg) == expected.lowercased() else { throw UpdateError.checksum }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pixora-update-\(version)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = mount.appendingPathComponent("Pixora.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.badBundle("không phải Pixora") }
        guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateError.badBundle("phiên bản trong DMG không khớp") }
        let staged = work.appendingPathComponent("Pixora.app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        return PreparedUpdate(staged: staged, version: version)
    }

    public struct PreparedUpdate: Sendable {
        public var staged: URL
        public var version: String

        /// Replaces `target` (the running app) after process `pid` exits, then reopens it.
        /// Runs as a detached shell so it outlives the app.
        public func relaunch(replacing target: URL = Bundle.main.bundleURL, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                             reopen: Bool = true) throws {
            let parent = target.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }
            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
            rm -rf "\(target.path).old" && mv "\(target.path)" "\(target.path).old" &&
              /usr/bin/ditto "\(staged.path)" "\(target.path)" && rm -rf "\(target.path).old" ||
              { rm -rf "\(target.path)"; mv "\(target.path).old" "\(target.path)"; }
            /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
            rm -rf "\(staged.deletingLastPathComponent().path)"
            \(reopen ? "/usr/bin/open \"\(target.path)\"" : "")
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        }
    }

    /// The Pixora.app that contains this executable (app or bundled CLI), if any.
    public static var installedApp: URL? {
        var u = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        while u.path != "/" {
            if u.pathExtension == "app" { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError.badBundle("\(URL(fileURLWithPath: tool).lastPathComponent): \(text.prefix(200))") }
        return text
    }
}
