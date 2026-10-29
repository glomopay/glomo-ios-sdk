import XCTest
@testable import GlomoPaySDK

final class MixpanelAnalyticsTrackerTests: XCTestCase {
    func testStandardProperties() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
            initialFlowType: "auto",
            transport: transport,
            deviceProperties: {
                [
                    "$model": "iPhone18,3",
                    "$os": "iOS",
                    "$os_version": "18.5",
                    "$app_namespace": "com.example.merchant",
                    "mp_lib": "glomo-ios-sdk",
                ]
            }
        )

        tracker.trackPageViewed(.loading)
        tracker.updateFlowType("lrs")
        tracker.trackPageViewed(.checkout)

        let first = try await transport.nextEvent().jsonProperties
        let second = try await transport.nextEvent().jsonProperties
        let events = [first, second]
        let beforeResolve = try XCTUnwrap(events.first { $0["page_name"] as? String == "loading" })
        let properties = try XCTUnwrap(events.first { $0["page_name"] as? String == "checkout" })
        XCTAssertNil(beforeResolve["journey"])
        XCTAssertEqual(properties["journey"] as? String, "lrs")
        XCTAssertEqual(properties["integration"] as? String, "ios_sdk")
        XCTAssertEqual(properties["platform"] as? String, "ios")
        XCTAssertEqual(properties["sdk_version"] as? String, "1.0.0")
        XCTAssertEqual(properties["public_key"] as? String, "test_public_key")
        XCTAssertEqual(properties["dev_mode"] as? Bool, false)
        XCTAssertEqual(properties["key_mode"] as? String, "test")
        XCTAssertEqual(properties["resource_id"] as? String, "order_123")
        XCTAssertEqual(properties["journey_id"] as? String, "session-uuid")
        XCTAssertEqual(properties["$device_id"] as? String, "session-uuid")
        XCTAssertEqual(properties["distinct_id"] as? String, "$device:session-uuid")
        XCTAssertNotNil(properties["$insert_id"] as? String)
        XCTAssertEqual(properties["time"] as? Int64, 1_723_620_000_000)
        XCTAssertEqual(properties["$model"] as? String, "iPhone18,3")
        XCTAssertEqual(properties["$os"] as? String, "iOS")
        for dropped in Self.droppedStandardKeys {
            XCTAssertNil(properties[dropped], dropped)
        }
        let keyPattern = try NSRegularExpression(pattern: #"^\$?[a-z0-9_]+$"#)
        for key in properties.keys {
            XCTAssertNotNil(
                keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
                "\(key) is not snake_case"
            )
        }
    }

    func testStandardPropertiesWinOverCallSiteKeys() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(
            transport: transport,
            deviceProperties: { ["$os": "iOS", "$model": "iPhone18,3"] }
        )

        tracker.track(AnalyticsEventName.sdkActionSubmitted, properties: [
            "action_name": "bank_redirect",
            "integration": "web",
            "platform": "web",
            "sdk_version": "9.9.9",
            "public_key": "live_other",
            "dev_mode": true,
            "key_mode": "live",
            "resource_id": "order_other",
            "journey": "lrs",
            "journey_id": "other-journey",
            "distinct_id": "other-user",
            "$os": "Android",
            "$model": "Pixel 8",
        ])

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertEqual(properties["action_name"] as? String, "bank_redirect")
        XCTAssertEqual(properties["integration"] as? String, "ios_sdk")
        XCTAssertEqual(properties["platform"] as? String, "ios")
        XCTAssertEqual(properties["sdk_version"] as? String, "1.0.0")
        XCTAssertEqual(properties["public_key"] as? String, "test_public_key")
        XCTAssertEqual(properties["dev_mode"] as? Bool, false)
        XCTAssertEqual(properties["key_mode"] as? String, "test")
        XCTAssertEqual(properties["resource_id"] as? String, "order_123")
        XCTAssertEqual(properties["journey"] as? String, "standard")
        XCTAssertEqual(properties["journey_id"] as? String, "session-uuid")
        XCTAssertEqual(properties["distinct_id"] as? String, "$device:session-uuid")
        XCTAssertEqual(properties["$os"] as? String, "iOS")
        XCTAssertEqual(properties["$model"] as? String, "iPhone18,3")
    }

    func testLiveKeysReportLiveKeyMode() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(
            config: GlomoPayConfig(publicKey: "live_public_key", orderId: "order_123"),
            transport: transport
        )

        tracker.trackPageViewed(.checkout)

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertEqual(properties["key_mode"] as? String, "live")
    }

    func testUnknownKeyPrefixLeavesKeyModeUnset() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(
            config: GlomoPayConfig(publicKey: "pk_without_prefix", orderId: "order_123"),
            transport: transport
        )

        tracker.trackPageViewed(.checkout)

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertNil(properties["key_mode"])
    }

    func testSubscriptionIsTheResourceAndTheJourneyButNotTheMixpanelIdentity() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", subscriptionId: "sub_123"),
            initialFlowType: "auto",
            transport: transport
        )

        tracker.trackPageViewed(.checkout)

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertEqual(properties["resource_id"] as? String, "sub_123")
        XCTAssertEqual(properties["journey"] as? String, "subscription")
        XCTAssertEqual(properties["distinct_id"] as? String, "$device:session-uuid")
        XCTAssertNil(properties["subscription_id"])
    }

    func testCheckoutURLJourneyIDMatchesTheJourneyIDOnEveryEvent() async throws {
        let journeyID = "01d245ac-f936-4545-9013-7114243e312f"
        let config = GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123")
        let url = try XCTUnwrap(ConfigManager.getCheckoutURL(config, journeyID: journeyID))
        let urlJourneyID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "journeyId" }?.value
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(config: config, sessionID: journeyID, transport: transport)

        tracker.trackPageViewed(.checkout)
        tracker.trackCheckoutClosed(.sdk, page: .checkout, paymentEvent: .paymentSuccess, hadListener: true)

        for _ in 0..<2 {
            let properties = try await transport.nextEvent().jsonProperties
            XCTAssertEqual(properties["journey_id"] as? String, urlJourneyID)
            XCTAssertEqual(properties["$device_id"] as? String, urlJourneyID)
            XCTAssertEqual(properties["distinct_id"] as? String, "$device:\(journeyID)")
            XCTAssertNotEqual(properties["distinct_id"] as? String, properties["resource_id"] as? String)
        }
    }

    func testEveryEventGetsItsOwnLowercaseInsertID() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(transport: transport)

        tracker.trackPageViewed(.bankRedirect)
        tracker.trackPageViewed(.bankRedirect)

        let first = try await transport.nextEvent().jsonProperties["$insert_id"] as? String
        let second = try await transport.nextEvent().jsonProperties["$insert_id"] as? String
        let insertIDs = try [XCTUnwrap(first), XCTUnwrap(second)]
        XCTAssertNotEqual(insertIDs[0], insertIDs[1])
        for insertID in insertIDs {
            XCTAssertNotNil(UUID(uuidString: insertID))
            XCTAssertEqual(insertID, insertID.lowercased())
        }
    }

    func testOnceEventsAreSentOncePerJourneyAndFailuresOncePerCode() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(transport: transport)

        for _ in 0..<2 {
            tracker.trackSDKLoaded()
            tracker.trackCheckoutFailed(.openTimeout(lastStep: "navigation_finished"))
            tracker.trackPageViewed(.educationCarousel)
            tracker.trackCheckoutClosed(.userDismiss, page: .checkout)
        }
        tracker.trackCheckoutFailed(.dependenciesFailedToLoad)
        tracker.trackPageViewed(.checkout)
        tracker.trackPageViewed(.checkout)
        tracker.trackPageViewed(.bankRedirect)
        tracker.trackPageViewed(.bankRedirect)

        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkPageViewed, count: 4)
        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutFailed, count: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let loaded = await transport.allEvents(named: AnalyticsEventName.sdkLoaded)
        let failed = await transport.allEvents(named: AnalyticsEventName.sdkCheckoutFailed)
        let viewed = await transport.allEvents(named: AnalyticsEventName.sdkPageViewed)
        let closed = await transport.allEvents(named: AnalyticsEventName.sdkCheckoutClosed)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(
            Set(failed.map { $0.jsonProperties["error_code"] as? String }),
            ["open_timeout", "dependencies_failed_to_load"]
        )
        XCTAssertEqual(failed.count, 2)
        let pages = viewed.map { $0.jsonProperties["page_name"] as? String ?? "" }
        XCTAssertEqual(pages.sorted(), ["bank_redirect", "bank_redirect", "checkout", "education_carousel"])
        XCTAssertEqual(closed.count, 1)
    }

    func testSDKLoadedCarriesTheBorrowedPropertySourceFields() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(
            sdkVersion: "1.2.3",
            initialFlowType: "auto",
            transport: transport,
            deviceProperties: {
                ["$os": "iOS", "$os_version": "18.5", "$model": "iPhone17,3"]
            }
        )

        tracker.trackSDKLoaded()

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

    func testResolvedNetworkSnapshotIsMergedIntoSubsequentEvents() async throws {
        let transport = RecordingAnalyticsTransport()
        let tracker = makeTracker(transport: transport)

        tracker.updateNetworkSnapshotProperties([
            "$wifi_enabled": true,
            "$cellular_enabled": false,
        ])
        tracker.trackPageViewed(.checkout)
        let properties = try await transport.nextEvent().jsonProperties

        XCTAssertEqual(properties["$wifi_enabled"] as? Bool, true)
        XCTAssertEqual(properties["$cellular_enabled"] as? Bool, false)
    }

    func testLongResourceIDIsCappedInsteadOfRejectingTheEvent() async throws {
        let transport = RecordingAnalyticsTransport()
        let orderID = "order_" + String(repeating: "a", count: 1_994)
        let tracker = makeTracker(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: orderID),
            transport: transport
        )

        tracker.trackPageViewed(.checkout)

        let properties = try await transport.nextEvent().jsonProperties
        XCTAssertEqual(properties["resource_id"] as? String, String(orderID.prefix(1_000)))
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

private func makeTracker(
    config: GlomoPayConfig = GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
    sessionID: String = "session-uuid",
    sdkVersion: String = "1.0.0",
    initialFlowType: String = "standard",
    transport: AnalyticsTransporting,
    deviceProperties: @escaping () -> [String: Any?] = { [:] }
) -> MixpanelAnalyticsTracker {
    MixpanelAnalyticsTracker(
        config: config,
        sessionID: sessionID,
        sdkVersion: sdkVersion,
        initialFlowType: initialFlowType,
        transport: transport,
        errorReporter: NoOpSDKErrorReporter(),
        deviceProperties: deviceProperties,
        now: { Date(timeIntervalSince1970: 1_723_620_000) }
    )
}

extension MixpanelAnalyticsTrackerTests {
    static let droppedStandardKeys = [
        "order_id", "subscription_id", "flow_type", "mock_mode", "session_id", "timestamp",
        "checkout_url", "sdk_source", "surface", "device_os_version",
    ]
}

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

    func recordedEvents() -> [AnalyticsEvent] {
        history
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
