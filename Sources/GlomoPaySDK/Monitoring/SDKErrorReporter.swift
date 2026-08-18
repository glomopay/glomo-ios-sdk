import Foundation

protocol SDKErrorReporting: AnyObject {
    func updateFlowType(_ flowType: String)
    func addBreadcrumb(category: String, message: String, data: [String: Any?])
    func capture(operation: String, error: Error, context: [String: Any?])
}

final class NoOpSDKErrorReporter: SDKErrorReporting {
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) {}
}
