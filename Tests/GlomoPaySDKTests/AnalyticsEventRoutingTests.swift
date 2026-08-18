import XCTest
@testable import GlomoPaySDK

final class AnalyticsEventRoutingTests: XCTestCase {
    func testPaymentAndEducationBridgeMessagesTrackExpectedEvents() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics
        )

        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.pending",
                "payload": ["orderId": "order_123", "paymentId": "pay_123"],
            ],
        ])
        router.handle(envelope: [
            "type": "message",
            "data": ["type": "lrs.has_education_steps", "value": true],
        ])

        XCTAssertEqual(analytics.events.map(\.name), [
            AnalyticsEventName.paymentPending,
            AnalyticsEventName.educationStepsShown,
        ])
    }

    func testMalformedMessageTracksInvalidMessageAndSDKError() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(listener: nil, devMode: false, onComplete: { _ in }, analytics: analytics)

        router.handle(body: "not-json")

        XCTAssertEqual(analytics.events.map(\.name), [
            AnalyticsEventName.invalidMessageReceived,
            AnalyticsEventName.sdkError,
        ])
    }

    func testAnalyticsContractContainsThirtyEightDistinctEvents() {
        let names = [
            AnalyticsEventName.sdkInitialized, AnalyticsEventName.sdkValidationFailed,
            AnalyticsEventName.deviceComplianceChecked, AnalyticsEventName.deviceComplianceBlocked,
            AnalyticsEventName.orderTypeDetectionStarted, AnalyticsEventName.orderTypeResolved,
            AnalyticsEventName.orderTypeDetectionFailed, AnalyticsEventName.checkoutStarted,
            AnalyticsEventName.checkoutURLResolved, AnalyticsEventName.navigationStarted,
            AnalyticsEventName.navigationFinished, AnalyticsEventName.navigationURLChange,
            AnalyticsEventName.redirectOpened, AnalyticsEventName.redirectClosed,
            AnalyticsEventName.redirectPageStarted, AnalyticsEventName.redirectPageFinished,
            AnalyticsEventName.redirectURLChange, AnalyticsEventName.paymentSuccess,
            AnalyticsEventName.paymentFailure, AnalyticsEventName.paymentPending,
            AnalyticsEventName.paymentCancelled, AnalyticsEventName.paymentTerminated,
            AnalyticsEventName.bankTransferSubmitted, AnalyticsEventName.payViaBankCompleted,
            AnalyticsEventName.connectionError, AnalyticsEventName.webViewHTTPError,
            AnalyticsEventName.webViewError, AnalyticsEventName.invalidMessageReceived,
            AnalyticsEventName.sdkError, AnalyticsEventName.checkoutDependenciesFailed,
            AnalyticsEventName.educationStepsShown, AnalyticsEventName.educationStepsFailed,
            AnalyticsEventName.fileUploadRequested, AnalyticsEventName.filePermissionDenied,
            AnalyticsEventName.filePickerError, AnalyticsEventName.iOSDocumentRetry,
            AnalyticsEventName.consoleLogCaptured, AnalyticsEventName.unsupportedFunctionalityUsed,
        ]

        XCTAssertEqual(names.count, 38)
        XCTAssertEqual(Set(names).count, 38)
    }
}

private final class RecordingAnalyticsTracker: AnalyticsTracking {
    struct RecordedEvent { let name: String; let properties: [String: Any?] }
    var events: [RecordedEvent] = []
    func track(_ event: String, properties: [String: Any?]) {
        events.append(RecordedEvent(name: event, properties: properties))
    }
    func updateFlowType(_ flowType: String) {}
    func updateCheckoutURL(_ url: URL) {}
}
