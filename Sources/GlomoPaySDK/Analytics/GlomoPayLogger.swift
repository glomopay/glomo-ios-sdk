import Foundation

public enum GlomoPayLogger {
    public static var devMode = false

    public static func log(_ message: String) {
        guard devMode else { return }
        print("[GlomoPay] \(message)")
    }

    public static func info(_ message: String) {
        guard devMode else { return }
        print("[GlomoPay][INFO] \(message)")
    }

    public static func error(_ message: String, error: Error? = nil) {
        guard devMode else { return }
        print("[GlomoPay][ERROR] \(message)\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }

    /// Release diagnostics never include event properties, checkout URLs, keys, or IDs.
    public static func analytics(_ message: String) {
        if devMode {
            print("[GlomoPay][Analytics] \(message)")
        }
    }
}
