import Foundation

public struct NamingOptions: Sendable, Codable {
    public var prefix = ""
    public var suffix = ""
    public var appendModel = false
    public var flatten = false

    public init(prefix: String = "", suffix: String = "", appendModel: Bool = false, flatten: Bool = false) {
        self.prefix = prefix
        self.suffix = suffix
        self.appendModel = appendModel
        self.flatten = flatten
    }
}

public enum Batch {
    /// Expands files and folders into image files; returns (file, path relative to its root folder).
    public static func collect(_ inputs: [URL], recursive: Bool) -> [(url: URL, relative: String)] {
        var out: [(URL, String)] = []
        let fm = FileManager.default
        for input in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                out.append((input, input.lastPathComponent))
                continue
            }
            let opts: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            guard let e = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey], options: opts) else { continue }
            let rootPath = input.standardizedFileURL.path
            for case let url as URL in e where ImageFile.supportedExtensions.contains(url.pathExtension.lowercased()) {
                let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                out.append((url, rel))
            }
        }
        return out.sorted { $0.0.path < $1.0.path }
    }

    public static func outputURL(for input: URL, relative: String, outputDirectory: URL?, format: OutputFormat,
                                 naming: NamingOptions, modeName: String, sizeTag: String) -> URL {
        let resolved = OutputFormat.resolve(format, sourceExtension: input.pathExtension)
        let base = input.deletingPathExtension().lastPathComponent
        var name = naming.prefix + base
        if naming.appendModel { name += "-\(modeName)-\(sizeTag)" }
        name += naming.suffix
        // Never overwrite the source by accident when no folder/suffix is given.
        let dir: URL
        if let outputDirectory {
            let sub = naming.flatten ? "" : (relative as NSString).deletingLastPathComponent
            dir = sub.isEmpty ? outputDirectory : outputDirectory.appendingPathComponent(sub)
        } else {
            dir = input.deletingLastPathComponent()
            if naming.prefix.isEmpty && naming.suffix.isEmpty && !naming.appendModel { name += "-pixgamma" }
        }
        let url = dir.appendingPathComponent(name).appendingPathExtension(resolved.fileExtension)
        // The output folder may be the source's own folder (or resolve to it), so check the final path too.
        guard isSameFile(url, input) else { return url }
        return dir.appendingPathComponent(name + "-pixgamma").appendingPathExtension(resolved.fileExtension)
    }

    /// Path comparison that follows symlinks and ignores case (APFS is case-insensitive by default).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }
        return key(a) == key(b)
    }

    public static func sizeTag(_ size: OutputSize) -> String {
        switch size {
        case .factor(let f): return String(format: "%gx", f)
        case .width(let w): return "w\(w)"
        case .height(let h): return "h\(h)"
        }
    }
}
