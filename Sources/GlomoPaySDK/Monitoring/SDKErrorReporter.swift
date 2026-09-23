import Foundation

protocol SDKErrorReporting: AnyObject, Sendable {
    func updateFlowType(_ flowType: String)
    func addBreadcrumb(category: String, message: String, data: [String: Any?])
    func capture(operation: String, error: Error, context: [String: Any?])
    func flush(timeout: TimeInterval)
}

extension SDKErrorReporting {
    func flush(timeout: TimeInterval) {}
}

enum SDKErrorReporterTerminalFlusher {
    static let timeout: TimeInterval = 1.5

    static func flush(_ reporter: SDKErrorReporting) {
        DispatchQueue.global(qos: .utility).async {
            reporter.flush(timeout: timeout)
        }
    }
}

final class NoOpSDKErrorReporter: SDKErrorReporting, @unchecked Sendable {
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) {}
}
