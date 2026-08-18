import XCTest
@testable import GlomoPaySDK

final class MixpanelAnalyticsTrackerTests: XCTestCase {
    func testTrackerAddsApprovedCommonProperties() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123", devMode: true),
            sessionID: "session-uuid",
            sdkVersion: "1.0.0",
            initialFlowType: "auto",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: {
                ["$model": "iPhone18,3", "$app_namespace": "com.example.merchant"]
            },
            now: { Date(timeIntervalSince1970: 1_723_620_000) }
        )

        tracker.updateFlowType("lrs")
        tracker.updateCheckoutURL(URL(string: "https://checkout.glomopay.com/?orderId=order_123")!)
        tracker.track(AnalyticsEventName.checkoutStarted)

        let event = try await transport.nextEvent()
        XCTAssertEqual(event.properties["distinct_id"] as? String, "order_123")
        XCTAssertEqual(event.properties["session_id"] as? String, "session-uuid")
        XCTAssertEqual(event.properties["$insert_id"] as? String, "session-uuid")
        XCTAssertEqual(event.properties["flow_type"] as? String, "lrs")
        XCTAssertEqual(event.properties["surface"] as? String, "ios-sdk")
        XCTAssertEqual(event.properties["platform"] as? String, "ios")
        XCTAssertEqual(event.properties["mock_mode"] as? Bool, true)
        XCTAssertEqual(event.properties["time"] as? Int64, 1_723_620_000_000)
        XCTAssertFalse((event.properties["timestamp"] as? String ?? "").contains("REDACTED"))
    }

    func testSubscriptionDoesNotInventOrderIdentity() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", subscriptionId: "sub_123"),
            sessionID: "session-uuid",
            sdkVersion: "1.0.0",
            initialFlowType: "standard",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: { [:] }
        )

        tracker.track(AnalyticsEventName.sdkInitialized)

        let properties = try await transport.nextEvent().properties
        XCTAssertTrue(properties["order_id"] is NSNull)
        XCTAssertTrue(properties["distinct_id"] is NSNull)
        XCTAssertEqual(properties["subscription_id"] as? String, "sub_123")
    }

    func testRuntimeConfigurationTrimsValuesAndDisablesBlankConfiguration() {
        let configured = SDKRuntimeConfiguration.load(environment: [
            "GLOMOPAY_MIXPANEL_TOKEN": " token ",
            "GLOMOPAY_SENTRY_DSN": " dsn ",
        ])
        let blank = SDKRuntimeConfiguration.load(environment: [
            "GLOMOPAY_MIXPANEL_TOKEN": "  ",
            "GLOMOPAY_SENTRY_DSN": "",
        ])

        XCTAssertEqual(configured.mixpanelToken, "token")
        XCTAssertEqual(configured.sentryDSN, "dsn")
        XCTAssertNil(blank.mixpanelToken)
        XCTAssertNil(blank.sentryDSN)
    }
}

private actor RecordingAnalyticsTransport: AnalyticsTransporting {
    private var events: [AnalyticsEvent] = []

    func send(_ event: AnalyticsEvent) async throws {
        events.append(event)
    }

    func nextEvent() async throws -> AnalyticsEvent {
        for _ in 0..<100 {
            if !events.isEmpty { return events.removeFirst() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RecordingError.timedOut
    }
}

private enum RecordingError: Error {
    case timedOut
}
