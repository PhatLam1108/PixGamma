import Foundation

/// Environment settings. PixGamma was called Pixora up to 0.2.1, so every `PIXGAMMA_X`
/// variable also accepts its old `PIXORA_X` name.
public enum Env {
    public static func get(_ name: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        return e["PIXGAMMA_" + name] ?? e["PIXORA_" + name]
    }

    public static func isSet(_ name: String) -> Bool { get(name) != nil }
}
