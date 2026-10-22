import XCTest
@testable import GlomoPaySDK

final class MixpanelAnalyticsTrackerTests: XCTestCase {
    func testTrackerAddsApprovedCommonProperties() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
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
        XCTAssertEqual(properties["distinct_id"] as? String, "$device:session-uuid")
        XCTAssertEqual(properties["$device_id"] as? String, "session-uuid")
        XCTAssertEqual(properties["journey_id"] as? String, "session-uuid")
        XCTAssertEqual(properties["session_id"] as? String, "session-uuid")
        XCTAssertEqual(properties["order_id"] as? String, "order_123")
        XCTAssertEqual(properties["flow_type"] as? String, "lrs")
        XCTAssertEqual(properties["surface"] as? String, "ios-sdk")
        XCTAssertEqual(properties["platform"] as? String, "ios")
        XCTAssertEqual(properties["mock_mode"] as? Bool, true)
        XCTAssertEqual(properties["time"] as? Int64, 1_723_620_000_000)
        XCTAssertFalse((properties["timestamp"] as? String ?? "").contains("REDACTED"))
    }

    func testSubscriptionIDStaysAPropertyAndIsNotTheMixpanelIdentity() async throws {
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
        XCTAssertEqual(properties["distinct_id"] as? String, "$device:session-uuid")
        XCTAssertEqual(properties["subscription_id"] as? String, "sub_123")
    }

    func testCheckoutURLJourneyIDMatchesTheJourneyIDOnEveryEvent() async throws {
        let journeyID = "01d245ac-f936-4545-9013-7114243e312f"
        let config = GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123")
        let url = try XCTUnwrap(ConfigManager.getCheckoutURL(config, journeyID: journeyID))
        let urlJourneyID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "journeyId" }?.value
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: config,
            sessionID: journeyID,
            sdkVersion: "1.0.0",
            initialFlowType: "standard",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: { [:] }
        )

        tracker.track(AnalyticsEventName.checkoutStarted)
        tracker.track(AnalyticsEventName.paymentSuccess, properties: ["payment_id": "pay_123"])

        for _ in 0..<2 {
            let properties = try await transport.nextEvent().jsonProperties
            XCTAssertEqual(properties["journey_id"] as? String, urlJourneyID)
            XCTAssertEqual(properties["$device_id"] as? String, urlJourneyID)
            XCTAssertEqual(properties["distinct_id"] as? String, "$device:\(journeyID)")
            XCTAssertNotEqual(properties["distinct_id"] as? String, properties["order_id"] as? String)
        }
    }

    func testEveryEventGetsItsOwnLowercaseInsertID() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
            sessionID: "session-uuid",
            sdkVersion: "1.0.0",
            initialFlowType: "standard",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: { [:] }
        )

        tracker.track(AnalyticsEventName.checkoutStarted)
        tracker.track(AnalyticsEventName.checkoutStarted)

        let first = try await transport.nextEvent().jsonProperties["$insert_id"] as? String
        let second = try await transport.nextEvent().jsonProperties["$insert_id"] as? String
        let insertIDs = try [XCTUnwrap(first), XCTUnwrap(second)]
        XCTAssertNotEqual(insertIDs[0], insertIDs[1])
        for insertID in insertIDs {
            XCTAssertNotNil(UUID(uuidString: insertID))
            XCTAssertEqual(insertID, insertID.lowercased())
        }
    }

    func testCheckoutURLIsSentWithoutItsQueryString() async throws {
        let config = GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123")
        let url = try XCTUnwrap(
            ConfigManager.getCheckoutURL(config, journeyID: "01d245ac-f936-4545-9013-7114243e312f")
        )
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: config,
            sessionID: "01d245ac-f936-4545-9013-7114243e312f",
            sdkVersion: "1.0.0",
            initialFlowType: "standard",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: { [:] }
        )

        tracker.updateCheckoutURL(url)
        tracker.track(AnalyticsEventName.checkoutStarted)

        let properties = try await transport.nextEvent().jsonProperties
        let checkoutURL = try XCTUnwrap(properties["checkout_url"] as? String)
        XCTAssertEqual(checkoutURL, "https://checkout.glomopay.com/")
        XCTAssertFalse(checkoutURL.contains("?"))
        XCTAssertFalse(checkoutURL.contains("journeyId"))
    }

    func testSDKLoadedCarriesTheBorrowedPropertySourceFields() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = MixpanelAnalyticsTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
            sessionID: "session-uuid",
            sdkVersion: "1.2.3",
            initialFlowType: "auto",
            transport: transport,
            errorReporter: NoOpSDKErrorReporter(),
            deviceProperties: {
                ["$os": "iOS", "$os_version": "18.5", "$model": "iPhone17,3"]
            }
        )

        tracker.track(AnalyticsEventName.sdkLoaded, properties: ["integration": "ios_sdk"])

        let event = try await transport.nextEvent()
        let properties = event.jsonProperties
        XCTAssertEqual(event.name, "sdk_loaded")
        XCTAssertEqual(properties["integration"] as? String, "ios_sdk")
        XCTAssertEqual(properties["sdk_version"] as? String, "1.2.3")
        XCTAssertEqual(properties["platform"] as? String, "ios")
        XCTAssertEqual(properties["$os"] as? String, "iOS")
        XCTAssertEqual(properties["$os_version"] as? String, "18.5")
        XCTAssertEqual(properties["$model"] as? String, "iPhone17,3")
        XCTAssertEqual(properties["journey_id"] as? String, "session-uuid")
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

    func testResolvedNetworkSnapshotIsMergedIntoSubsequentEvents() async throws {
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
            "$wifi_enabled": true,
            "$cellular_enabled": false,
        ])
        _ = try await transport.nextEvent()

        tracker.track(AnalyticsEventName.checkoutStarted)
        let properties = try await transport.nextEvent().jsonProperties

        XCTAssertEqual(properties["$wifi_enabled"] as? Bool, true)
        XCTAssertEqual(properties["$cellular_enabled"] as? Bool, false)
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

actor RecordingAnalyticsTransport: AnalyticsTransporting {
    private var events: [AnalyticsEvent] = []
    private var history: [AnalyticsEvent] = []
    private var eventReceived: XCTestExpectation?

    func send(_ event: AnalyticsEvent) async throws {
        events.append(event)
        history.append(event)
        eventReceived?.fulfill()
        eventReceived = nil
    }

    func nextEvent() async throws -> AnalyticsEvent {
        if events.isEmpty {
            let received = XCTestExpectation(description: "analytics transport received event")
            eventReceived = received
            // A utility-priority task can be delayed while the simulator starts WebKit.
            let result = await XCTWaiter.fulfillment(of: [received], timeout: 30)
            eventReceived = nil
            guard result == .completed else { throw RecordingError.timedOut }
        }
        return events.removeFirst()
    }

    func allEvents(named name: String) -> [AnalyticsEvent] {
        history.filter { $0.name == name }
    }

    func waitForEvents(named name: String, count: Int) async throws -> [AnalyticsEvent] {
        for _ in 0..<300 {
            let matching = allEvents(named: name)
            if matching.count >= count { return matching }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RecordingError.timedOut
    }
}

private enum RecordingError: Error {
    case timedOut
}
