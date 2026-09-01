import Foundation

protocol SDKErrorReporting: AnyObject, Sendable {
    func updateFlowType(_ flowType: String)
    func addBreadcrumb(category: String, message: String, data: [String: Any?])
    func capture(operation: String, error: Error, context: [String: Any?])
}

final class NoOpSDKErrorReporter: SDKErrorReporting, @unchecked Sendable {
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) {}
}
