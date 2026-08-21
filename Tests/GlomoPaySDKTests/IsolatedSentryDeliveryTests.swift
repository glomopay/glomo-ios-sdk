import XCTest
@testable import GlomoPaySDK

final class IsolatedSentryDeliveryTests: XCTestCase {
    func testManualSDKErrorDelivery() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GLOMOPAY_RUN_SENTRY_DELIVERY_TEST"] == "1",
            "Set GLOMOPAY_RUN_SENTRY_DELIVERY_TEST=1 to send the synthetic SDK event."
        )

        let configuration = SDKRuntimeConfiguration.load()
        let dsn = try XCTUnwrap(
            configuration.sentryDSN,
            "The SDK-owned Sentry DSN is not configured."
        )
        let reporter = IsolatedSentryErrorReporter(
            dsn: dsn,
            sessionID: UUID().uuidString,
            initialFlowType: "diagnostic",
            devMode: true
        )

        reporter.addBreadcrumb(
            category: "sdk_diagnostic",
            message: "Manual isolated Sentry delivery test started",
            data: ["source": "swift_test"]
        )
        reporter.capture(
            operation: "manual_sentry_delivery_test",
            error: SyntheticSDKError(),
            context: [
                "event_name": "sdk.sentry_delivery_test",
                "error_type": "synthetic_test_error",
                "source": "swift_test",
            ]
        )
        reporter.flush(timeout: 10)
    }
}

private struct SyntheticSDKError: LocalizedError {
    var errorDescription: String? {
        "Synthetic SDK error generated to verify isolated Sentry delivery."
    }
}
