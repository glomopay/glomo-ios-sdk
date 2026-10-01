import Foundation

protocol AnalyticsTracking: AnyObject {
    func track(_ event: String, properties: [String: Any?])
    func updateFlowType(_ flowType: String)
    func updateCheckoutURL(_ url: URL)
    func updateNetworkSnapshotProperties(_ properties: [String: Any?])
}

extension AnalyticsTracking {
    func track(_ event: String) {
        track(event, properties: [:])
    }

    func updateNetworkSnapshotProperties(_ properties: [String: Any?]) {}
}

final class NoOpAnalyticsTracker: AnalyticsTracking {
    func track(_ event: String, properties: [String: Any?]) {}
    func updateFlowType(_ flowType: String) {}
    func updateCheckoutURL(_ url: URL) {}
}

enum AnalyticsEventName {
    static let sdkInitialized = "SDK Initialized"
    static let sdkValidationFailed = "SDK Validation Failed"
    static let deviceComplianceChecked = "Device Compliance Checked"
    static let deviceComplianceBlocked = "Device Compliance Blocked"
    static let orderTypeDetectionStarted = "Order Type Detection Started"
    static let orderTypeResolved = "Order Type Resolved"
    static let orderTypeDetectionFailed = "Order Type Detection Failed"
    static let checkoutStarted = "Checkout Started"
    static let checkoutURLResolved = "Checkout URL Resolved"
    static let checkoutWebViewCreated = "Checkout WebView Created"
    static let checkoutBridgeReady = "Checkout Bridge Ready"
    /// Carries `last_step` and a required `reason` (`render_timeout` or `watchdog`).
    static let checkoutOpenTimeout = "Checkout Open Timeout"
    /// The page arrived after a timeout was already reported. Not a correction, and the
    /// difference between the two counts is not a failure rate.
    static let checkoutOpenedAfterTimeout = "Checkout Opened After Timeout"
    static let listenerUnavailable = "Listener Unavailable"
    static let navigationStarted = "Navigation Started"
    static let navigationFinished = "Navigation Finished"
    static let navigationURLChange = "Navigation URL Change"
    static let redirectOpened = "Redirect Opened"
    static let redirectClosed = "Redirect Closed"
    static let redirectPageStarted = "Redirect Page Started"
    static let redirectPageFinished = "Redirect Page Finished"
    static let redirectURLChange = "Redirect URL Change"
    static let paymentSuccess = "Payment Success"
    static let paymentFailure = "Payment Failure"
    static let paymentPending = "Payment Pending"
    static let paymentCancelled = "Payment Cancelled"
    static let paymentTerminated = "Payment Terminated"
    static let bankTransferSubmitted = "Bank Transfer Submitted"
    // No payViaBankCompleted: pay-via-bank is sunset and unsupported on iOS, and an event that
    // fires with no callback behind it made dashboards show a journey no merchant is told about.
    static let connectionError = "Connection Error"
    static let webViewHTTPError = "WebView HTTP Error"
    static let webViewError = "WebView Error"
    static let invalidMessageReceived = "Invalid Message Received"
    static let sdkError = "SDK Error"
    static let checkoutDependenciesFailed = "Checkout Dependencies Failed"
    static let educationStepsShown = "Education Steps Shown"
    static let educationStepsFailed = "Education Steps Failed"
    static let fileUploadRequested = "File Upload Requested"
    // TODO: Restore these two events if iOS introduces its own file picker flow. The SDK
    // deliberately does not implement runOpenPanelWith, so WebKit owns the picker and there is
    // no picker path to report from. See the file-upload note in README.
    // static let filePermissionDenied = "File Permission Denied"
    // static let filePickerError = "File Picker Error"
    static let nonHTTPNavigationAttempted = "Non HTTP Navigation Attempted"
    static let iOSDocumentRetry = "iOS Document Retry"
    static let consoleLogCaptured = "Console Log Captured"
    static let unsupportedFunctionalityUsed = "Unsupported Functionality Used"
}

enum GlomoPaySDKBuild {
    static let version = "0.0.1"
}
