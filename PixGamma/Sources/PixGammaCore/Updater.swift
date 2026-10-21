import CryptoKit
import Foundation
import Security

/// Self-update from the GitHub releases of the public PixGamma repository.
///
/// No token is needed. One saved in the login Keychain (or `PIXGAMMA_GITHUB_TOKEN`) is still
/// sent when present, which lifts GitHub's unauthenticated limit of 60 requests an hour per
/// IP address. A release must carry
/// `PixGamma-<version>.dmg` and `PixGamma-<version>.dmg.sha256` (made by scripts/make_dmg.sh;
/// it also makes `Pixora-<version>.dmg` for apps from before the rename);
/// the download is only installed when its SHA-256 matches and the app inside reports the
/// release's version and PixGamma's bundle id.
public enum Updater {
    public static let repository = "PhatLam1108/PixGamma"
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
        case unauthorized, notFound, rateLimited(Date?), network(String), noInstaller(String), checksum, badBundle(String), notWritable(String)
        public var errorDescription: String? {
            switch self {
            case .unauthorized: return "Token GitHub đã lưu không hợp lệ hoặc đã hết hạn. Repo PixGamma công khai nên không cần token: hãy xoá token rồi thử lại."
            case .notFound: return "Không tìm thấy bản phát hành nào của PixGamma trên GitHub."
            case .rateLimited(let reset):
                let when = reset.map { " Thử lại sau \($0.formatted(date: .omitted, time: .shortened))," } ?? " Thử lại sau ít phút,"
                return "GitHub giới hạn 60 lần kiểm tra mỗi giờ cho mỗi địa chỉ IP khi không có token, và đã hết lượt.\(when) hoặc dùng một token GitHub (không cần quyền gì) để có 5.000 lượt mỗi giờ."
            case .network(let m): return "Không kết nối được GitHub: \(m)"
            case .noInstaller(let v): return "Bản \(v) chưa có file cài đặt .dmg."
            case .checksum: return "File tải về không khớp mã SHA-256, đã huỷ cài đặt."
            case .badBundle(let m): return "File cài đặt không hợp lệ: \(m)"
            case .notWritable(let p): return "Không ghi được vào \(p). Hãy kéo PixGamma vào Applications bằng tay từ file DMG."
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

    /// `PIXGAMMA_GITHUB_TOKEN` (not stored) wins over the Keychain, for scripts and CI.
    public static var token: String? {
        if let env = Env.get("GITHUB_TOKEN"), !env.isEmpty { return env }
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

    /// Without a token the request is anonymous, which is enough for the public repo.
    static func request(_ url: URL, accept: String, token: String?) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("PixGamma/\(APIServer.version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Latest published (non-draft, non-prerelease) release.
    public static func latest(token: String? = Updater.token) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: request(url, accept: "application/vnd.github+json", token: token)) }
        catch { throw UpdateError.network(error.localizedDescription) }
        try check(resp as? HTTPURLResponse)
        return try parseRelease(data)
    }

    /// Maps a GitHub API status to an `UpdateError`; 403/429 with no requests left is the rate limit.
    static func check(_ resp: HTTPURLResponse?) throws {
        let code = resp?.statusCode ?? 0
        let exhausted = resp?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
        switch code {
        case 200: return
        case 401: throw UpdateError.unauthorized
        case 403 where exhausted, 429 where exhausted:
            let reset = resp?.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw UpdateError.rateLimited(reset)
        case 404: throw UpdateError.notFound
        default: throw UpdateError.network("HTTP \(code)")
        }
    }

    public static func parseRelease(_ data: Data) throws -> Release {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { throw UpdateError.network("phản hồi không đọc được") }
        let version = String(tag.drop { $0 == "v" || $0 == "V" })
        let assets: [Asset] = (j["assets"] as? [[String: Any]] ?? []).compactMap { a in
            guard let n = a["name"] as? String, let u = (a["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Asset(name: n, apiURL: u, size: a["size"] as? Int ?? 0)
        }
        // Releases also carry a Pixora-<version>.dmg for apps from before the rename.
        let dmg = assets.first { $0.name.hasPrefix("PixGamma-") && $0.name.hasSuffix(".dmg") }
            ?? assets.first { $0.name.hasPrefix("Pixora-") && $0.name.hasSuffix(".dmg") }
        let published = (j["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: version, notes: j["body"] as? String ?? "", published: published,
                       dmg: dmg, checksum: dmg.flatMap { d in assets.first { $0.name == d.name + ".sha256" } })
    }

    // MARK: Download

    /// Asset downloads redirect to a signed storage URL that rejects the GitHub token,
    /// so the Authorization header (if any) is dropped on redirect.
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
                try Updater.check(downloadTask.response as? HTTPURLResponse)
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume(returning: dest)
            } catch { continuation?.resume(throwing: error) }
            continuation = nil
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation?.resume(throwing: UpdateError.network(error.localizedDescription)); continuation = nil }
        }
    }

    static func download(_ asset: Asset, token: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
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

    /// Downloads and verifies the DMG, copies the new PixGamma.app out of it and returns a
    /// prepared installer; `relaunch` replaces `target` once this process has quit.
    public static func prepare(_ r: Release, token: String? = Updater.token,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate {
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

    /// Verifies a downloaded installer and copies its PixGamma.app to a private folder.
    public static func stage(dmg: URL, sha256 expected: String, version: String) throws -> PreparedUpdate {
        guard try sha256(of: dmg) == expected.lowercased() else { throw UpdateError.checksum }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pixgamma-update-\(version)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = ["PixGamma.app", "Pixora.app"].map { mount.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? mount.appendingPathComponent("PixGamma.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.badBundle("không phải PixGamma") }
        guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateError.badBundle("phiên bản trong DMG không khớp") }
        let staged = work.appendingPathComponent("PixGamma.app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        return PreparedUpdate(staged: staged, version: version)
    }

    public struct PreparedUpdate: Sendable {
        public var staged: URL
        public var version: String

        /// Where the update lands: next to `target`, renamed from Pixora.app to PixGamma.app.
        public static func destination(replacing target: URL) -> URL {
            target.lastPathComponent == "Pixora.app"
                ? target.deletingLastPathComponent().appendingPathComponent("PixGamma.app") : target
        }

        /// Replaces `target` (the running app) after process `pid` exits, then reopens it.
        /// An app still named Pixora.app (from before the rename) comes back as PixGamma.app.
        /// Runs as a detached shell so it outlives the app.
        public func relaunch(replacing target: URL = Bundle.main.bundleURL, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                             reopen: Bool = true) throws {
            let parent = target.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }
            let dest = Self.destination(replacing: target)
            let clearDest = dest == target ? "" : "rm -rf \"\(dest.path)\" && "
            // CLI links made for Pixora.app point at Contents/Helpers/pixora; re-point them.
            let relink = dest == target ? "" : """
            for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
              if [ -L "$d/pixora" ] && readlink "$d/pixora" | grep -q "Pixora.app"; then
                ln -sf "\(dest.path)/Contents/Helpers/pixgamma" "$d/pixora"
                ln -sf "\(dest.path)/Contents/Helpers/pixgamma" "$d/pixgamma"
              fi
            done 2>/dev/null
            """
            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
            rm -rf "\(target.path).old" && mv "\(target.path)" "\(target.path).old" && \(clearDest)
              /usr/bin/ditto "\(staged.path)" "\(dest.path)" && rm -rf "\(target.path).old" ||
              { rm -rf "\(dest.path)"; mv "\(target.path).old" "\(target.path)"; }
            /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
            \(relink)
            rm -rf "\(staged.deletingLastPathComponent().path)"
            \(reopen ? "/usr/bin/open \"\(dest.path)\"" : "")
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        }
    }

    /// The PixGamma.app that contains this executable (app or bundled CLI), if any.
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
