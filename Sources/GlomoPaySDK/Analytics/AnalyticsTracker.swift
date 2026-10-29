import Foundation

protocol AnalyticsTracking: AnyObject {
    func track(_ event: String, properties: [String: Any?])
    func updateFlowType(_ flowType: String)
    func updateNetworkSnapshotProperties(_ properties: [String: Any?])
}

extension AnalyticsTracking {
    func updateNetworkSnapshotProperties(_ properties: [String: Any?]) {}
}

final class NoOpAnalyticsTracker: AnalyticsTracking {
    func track(_ event: String, properties: [String: Any?]) {}
    func updateFlowType(_ flowType: String) {}
}

enum AnalyticsEventName {
    static let sdkLoaded = "sdk_loaded"
    static let sdkPageViewed = "sdk_page_viewed"
    static let sdkAPIBackend = "sdk_api_backend"
    static let sdkActionSubmitted = "sdk_action_submitted"
    static let sdkActionFailed = "sdk_action_failed"
    static let sdkCTAClicked = "sdk_cta_clicked"
    static let sdkControlChanged = "sdk_control_changed"
    static let sdkCheckoutFailed = "sdk_checkout_failed"
    static let sdkCheckoutClosed = "sdk_checkout_closed"
}

enum GlomoPaySDKBuild {
    static let version = "1.0.0"
}
