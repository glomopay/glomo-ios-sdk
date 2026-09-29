import XCTest
@testable import GlomoPaySDK

/// Opt-in, skipped by default: sends one real, clearly marked test event to a Sentry project.
///
/// Set `GLOMOPAY_RUN_SENTRY_DELIVERY_TEST=1`. The DSN comes from `GLOMOPAY_SENTRY_DSN`, falling
/// back to the bundled resource. Under `xcodebuild test` on a simulator, prefix both with
/// `TEST_RUNNER_` so they reach the test process. The DSN is never printed.
///
/// It captures through `SentryEnvelopeClient` directly rather than the reporter, because the
/// reporter's tags and message format are fixed and this event must carry a `delivery_test` tag
/// and a "safe to resolve" message so nobody mistakes it for a production failure.
final class IsolatedSentryDeliveryTests: XCTestCase {
    func testManualSDKErrorDelivery() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GLOMOPAY_RUN_SENTRY_DELIVERY_TEST"] == "1",
            "Set GLOMOPAY_RUN_SENTRY_DELIVERY_TEST=1 to send the synthetic SDK event."
        )

        let dsnSource = (environment["GLOMOPAY_SENTRY_DSN"]?.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { $0.isEmpty ? "bundled resource" : "environment" } ?? "bundled resource"
        let configuration = SDKRuntimeConfiguration.load()
        let dsn = try XCTUnwrap(configuration.sentryDSN, "No Sentry DSN is configured.")
        let client = try XCTUnwrap(SentryEnvelopeClient(dsn: dsn), "The Sentry DSN is blank or malformed.")

        let runID = "delivery-test-\(Int(Date().timeIntervalSince1970))"
        let event: [String: Any] = [
            "level": "error",
            "logger": IsolatedSentryErrorReporter.logger,
            "message": ["formatted": "GlomoPay SDK delivery test - safe to resolve (\(runID))"],
            "tags": [
                "sdk_source": "glomo-ios-sdk",
                "operation": "delivery_test",
                "flow_type": "diagnostic",
                "dev_mode": String(SDKBuildFlags.internalBuild),
                "delivery_test": "true",
            ],
            "extra": [
                "session_id": runID,
                "source": "swift_test",
            ],
            "breadcrumbs": ["values": [[
                "timestamp": SentryEnvelope.timestamp(Date()),
                "level": "info",
                "category": "sdk_diagnostic",
                "message": "GlomoPay SDK delivery test started",
            ]]],
        ]

        let answered = expectation(description: "Sentry answered")
        let box = OutcomeBox()
        let sentAt = Date()
        client.capture(event: event) { outcome in
            box.set(outcome)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 30)

        guard case let .responded(eventID, statusCode) = try XCTUnwrap(box.value) else {
            XCTFail("Sentry did not answer: \(String(describing: box.value))")
            return
        }
        let ist = DateFormatter()
        ist.locale = Locale(identifier: "en_US_POSIX")
        ist.timeZone = TimeZone(identifier: "Asia/Kolkata")
        ist.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS 'IST'"
        print("[GlomoPay delivery test] dsn_source=\(dsnSource) run_id=\(runID) event_id=\(eventID) "
            + "http_status=\(statusCode) sent_at=\(ist.string(from: sentAt))")
        XCTAssertEqual(statusCode, 200)
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SentrySendOutcome?

    var value: SentrySendOutcome? { lock.glomoWithLock { stored } }

    func set(_ outcome: SentrySendOutcome) {
        lock.glomoWithLock { stored = outcome }
    }
}
