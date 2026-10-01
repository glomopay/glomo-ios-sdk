import Foundation

enum GlomoPayLogger {
    /// Internal and compile-time only. It used to be a public `static var`, which any merchant
    /// could set process-wide from their own code while the controller's init assigned it from
    /// the config - two unsynchronised writers owning one global.
    static let devMode = SDKBuildFlags.internalBuild

    static func log(_ message: String) {
        guard devMode else { return }
        print("[GlomoPay] \(message)")
    }

    static func info(_ message: String) {
        guard devMode else { return }
        print("[GlomoPay][INFO] \(message)")
    }

    static func error(_ message: String, error: Error? = nil) {
        guard devMode else { return }
        print("[GlomoPay][ERROR] \(message)\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }
}
