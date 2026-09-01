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
        let properties = event.jsonProperties
        XCTAssertEqual(properties["distinct_id"] as? String, "order_123")
        XCTAssertEqual(properties["session_id"] as? String, "session-uuid")
        XCTAssertNil(properties["$insert_id"])
        XCTAssertEqual(properties["flow_type"] as? String, "lrs")
        XCTAssertEqual(properties["surface"] as? String, "ios-sdk")
        XCTAssertEqual(properties["platform"] as? String, "ios")
        XCTAssertEqual(properties["mock_mode"] as? Bool, true)
        XCTAssertEqual(properties["time"] as? Int64, 1_723_620_000_000)
        XCTAssertFalse((properties["timestamp"] as? String ?? "").contains("REDACTED"))
    }

    func testSubscriptionUsesSubscriptionIDAsMixpanelOrderIdentity() async throws {
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

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertEqual(properties["order_id"] as? String, "sub_123")
        XCTAssertEqual(properties["distinct_id"] as? String, "sub_123")
        XCTAssertEqual(properties["subscription_id"] as? String, "sub_123")
    }

    func testSDKInitializedIncludesPerformanceSnapshotProperties() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
            sessionID: "session-uuid",
            sdkVersion: "1.0.0",
            initialFlowType: "auto",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: { [:] }
        )

        tracker.track(AnalyticsEventName.sdkInitialized, properties: [
            "perf_snapshot_at": "sdk_initialized",
            "battery_level_percent": 42,
            "thermal_state": "serious",
            "ram_available_bytes": Int64(120_000_000),
        ])

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertEqual(properties["perf_snapshot_at"] as? String, "sdk_initialized")
        XCTAssertEqual(properties["battery_level_percent"] as? Int64, 42)
        XCTAssertEqual(properties["thermal_state"] as? String, "serious")
        XCTAssertEqual(properties["ram_available_bytes"] as? Int64, 120_000_000)
    }

    func testRuntimeConfigurationTrimsValuesAndDisablesBlankConfiguration() {
        let configured = SDKRuntimeConfiguration.load(environment: [
            "GLOMOPAY_MIXPANEL_TOKEN": " token ",
            "GLOMOPAY_SENTRY_DSN": " dsn ",
        ], bundledValues: [:])
        let blank = SDKRuntimeConfiguration.load(environment: [
            "GLOMOPAY_MIXPANEL_TOKEN": "  ",
            "GLOMOPAY_SENTRY_DSN": "",
        ], bundledValues: [:])

        XCTAssertEqual(configured.mixpanelToken, "token")
        XCTAssertEqual(configured.sentryDSN, "dsn")
        XCTAssertNil(blank.mixpanelToken)
        XCTAssertNil(blank.sentryDSN)
    }

    func testRuntimeConfigurationFallsBackToSDKOwnedValues() {
        let configuration = SDKRuntimeConfiguration.load(
            environment: [:],
            bundledValues: [
                "GLOMOPAY_MIXPANEL_TOKEN": " bundled-token ",
                "GLOMOPAY_SENTRY_DSN": " bundled-dsn ",
            ]
        )

        XCTAssertEqual(configuration.mixpanelToken, "bundled-token")
        XCTAssertEqual(configuration.sentryDSN, "bundled-dsn")
    }

    func testRuntimeConfigurationAllowsLocalEnvironmentOverride() {
        let configuration = SDKRuntimeConfiguration.load(
            environment: [
                "GLOMOPAY_MIXPANEL_TOKEN": "local-token",
                "GLOMOPAY_SENTRY_DSN": "local-dsn",
            ],
            bundledValues: [
                "GLOMOPAY_MIXPANEL_TOKEN": "bundled-token",
                "GLOMOPAY_SENTRY_DSN": "bundled-dsn",
            ]
        )

        XCTAssertEqual(configuration.mixpanelToken, "local-token")
        XCTAssertEqual(configuration.sentryDSN, "local-dsn")
    }

    func testAnalyticsEventUsesSendableJSONRepresentation() throws {
        let values = AnalyticsValue.properties(from: [
            "string": "value",
            "integer": Int64(42),
            "double": 1.5,
            "boolean": true,
            "null": NSNull(),
            "array": ["value", 2],
            "object": ["nested": "value"],
        ])
        let event = AnalyticsEvent(name: "Test Event", properties: values)

        assertSendable(AnalyticsEvent.self)
        XCTAssertEqual(values["string"], .string("value"))
        XCTAssertEqual(values["integer"], .integer(42))
        XCTAssertEqual(values["boolean"], .bool(true))
        XCTAssertTrue(JSONSerialization.isValidJSONObject([
            "event": event.name,
            "properties": event.jsonProperties,
        ]))
    }
}

private func assertSendable<T: Sendable>(_: T.Type) {}

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
