import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import GlomoPaySDK

/// Behaviour of SDK error reporting as observed on the wire. See `SentryWire` for why requests
/// are intercepted at the `URLSession` boundary rather than by substituting SDK types.
final class IsolatedSentryErrorReporterTests: XCTestCase {
    /// Generous so a starved CI scheduler cannot let a flush expire before a response is handled;
    /// a healthy run finishes each send in milliseconds.
    private let deliveryTimeout: TimeInterval = 30

    // MARK: Envelope format

    func testCaptureSendsOneNewlineDelimitedEventEnvelope() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        // Multi-byte on purpose: the declared item length must be bytes, not characters.
        reporter.addBreadcrumb(category: "checkout", message: "₹1,000 भुगतान", data: [:])
        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(wire.requests.count, 1)
        XCTAssertEqual(request.lines.count, 3)
        XCTAssertEqual(request.body.last, 0x0A)

        let header = try request.envelopeHeader()
        let eventID = try XCTUnwrap(header["event_id"] as? String)
        XCTAssertEqual(eventID.count, 32)
        XCTAssertTrue(eventID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(header["dsn"] as? String, wire.dsn)
        let sentAt = try XCTUnwrap(header["sent_at"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: sentAt), sentAt)

        let itemHeader = try request.itemHeader()
        XCTAssertEqual(itemHeader["type"] as? String, "event")
        let payload = request.lines[2]
        XCTAssertEqual(itemHeader["length"] as? Int, payload.count)
        XCTAssertNotEqual(payload.count, String(decoding: payload, as: UTF8.self).count)

        XCTAssertEqual(try request.event()["event_id"] as? String, eventID)
    }

    func testRequestTargetsTheEndpointDerivedFromTheDSNWithSentryAuth() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first).request
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://\(wire.host)/api/\(SentryWire.projectID)/envelope/"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-sentry-envelope")
        XCTAssertEqual(request.timeoutInterval, 10)
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Sentry-Auth"))
        XCTAssertTrue(auth.hasPrefix("Sentry "), auth)
        XCTAssertTrue(auth.contains("sentry_version=7"), auth)
        XCTAssertTrue(auth.contains("sentry_key=\(SentryWire.publicKey)"), auth)
        XCTAssertTrue(auth.contains("sentry_client=glomo-ios-sdk/\(GlomoPaySDKBuild.version)"), auth)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "glomo-ios-sdk/\(GlomoPaySDKBuild.version)"
        )
        XCTAssertFalse(auth.contains("sentry_secret"), auth)
    }

    // Guards against a hard-coded region: only the DSN host differs, and it must be what is hit.
    func testIngestHostComesFromTheDSN() throws {
        let deWire = SentryWire(hostPrefix: "o4500000000000000.ingest.de")
        let usWire = SentryWire(hostPrefix: "o4500000000000000.ingest.us")

        for wire in [deWire, usWire] {
            let reporter = try makeReporter(wire)
            reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
            reporter.flush(timeout: deliveryTimeout)
        }

        XCTAssertEqual(deWire.requests.map { $0.request.url?.host }, [deWire.host])
        XCTAssertEqual(usWire.requests.map { $0.request.url?.host }, [usWire.host])
    }

    func testSelfHostedDSNKeepsPortPathPrefixAndSecret() throws {
        let wire = SentryWire()
        let client = try wire.makeClient(dsn: "http://fakepublic:fakesecret@\(wire.host):9000/prefix/7")
        let reporter = IsolatedSentryErrorReporter(
            client: client,
            sessionID: "session-uuid",
            initialFlowType: "standard",
            devMode: false
        )

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first).request
        XCTAssertEqual(request.url?.absoluteString, "http://\(wire.host):9000/prefix/api/7/envelope/")
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Sentry-Auth"))
        XCTAssertTrue(auth.contains("sentry_key=fakepublic"), auth)
        XCTAssertTrue(auth.contains("sentry_secret=fakesecret"), auth)
    }

    // MARK: Production construction path
    //
    // Production builds the reporter one way: telemetry values (environment, then the bundled
    // plist) -> `SDKRuntimeConfiguration.load` -> `SDKTelemetryRuntime` -> `SDKErrorReporterFactory`.
    // These tests go through all of it.

    func testMissingOrBlankDSNInConfigurationGivesTheNoOpReporter() {
        let cases: [(environment: [String: String], bundled: [String: String])] = [
            ([:], [:]),
            ([:], ["GLOMOPAY_SENTRY_DSN": ""]),
            ([:], ["GLOMOPAY_SENTRY_DSN": " \n "]),
            (["GLOMOPAY_SENTRY_DSN": "  "], ["GLOMOPAY_SENTRY_DSN": ""]),
            ([:], ["GLOMOPAY_MIXPANEL_TOKEN": "token-only"]),
        ]

        for (environment, bundled) in cases {
            let reporter = reporterFromConfiguration(environment: environment, bundled: bundled)
            XCTAssertTrue(reporter is NoOpSDKErrorReporter, "\(environment) \(bundled)")
        }
    }

    func testMalformedDSNInConfigurationGivesTheNoOpReporter() {
        let malformed = [
            "not a dsn",
            "ftp://key@example.test/1",
            "https://example.test/1",
            "https://key@example.test",
            "https://key@example.test/",
            "https://key@/1",
        ]

        for dsn in malformed {
            XCTAssertNil(SentryEnvelopeClient(dsn: dsn), dsn)
            let reporter = reporterFromConfiguration(environment: [:], bundled: ["GLOMOPAY_SENTRY_DSN": dsn])
            XCTAssertTrue(reporter is NoOpSDKErrorReporter, dsn)
        }
    }

    func testValidConfigurationReportsThroughTheFactoryWithTheCheckoutOrderID() throws {
        let wire = SentryWire()
        let reporter = reporterFromConfiguration(
            environment: [:],
            bundled: ["GLOMOPAY_SENTRY_DSN": " \(wire.dsn) "],
            sessionConfiguration: wire.sessionConfiguration(),
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_test_123"),
            flowType: "lrs"
        )

        reporter.capture(operation: "order_fetch", error: SyntheticError(), context: ["source": "api"])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(wire.requests.count, 1)
        let event = try request.event()
        let tags = try XCTUnwrap(event["tags"] as? [String: String])
        XCTAssertEqual(tags["order_id"], "order_test_123")
        XCTAssertEqual(tags["flow_type"], "lrs")
        XCTAssertEqual(tags["operation"], "order_fetch")
        XCTAssertEqual((event["extra"] as? [String: Any])?["source"] as? String, "api")
    }

    func testEnvironmentDSNTakesPrecedenceOverTheBundledOne() throws {
        let environmentWire = SentryWire()
        let bundledWire = SentryWire()
        let configuration = environmentWire.sessionConfiguration()
        let reporter = reporterFromConfiguration(
            environment: ["GLOMOPAY_SENTRY_DSN": environmentWire.dsn],
            bundled: ["GLOMOPAY_SENTRY_DSN": bundledWire.dsn],
            sessionConfiguration: configuration
        )

        reporter.capture(operation: "order_fetch", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        XCTAssertEqual(environmentWire.requests.count, 1)
        XCTAssertEqual(bundledWire.requests.count, 0)
    }

    // The shipped resource is what merchants get. A renamed key or resource would silently turn
    // error reporting off for every merchant, so read the real one and follow it to the request
    // it would make. The request is intercepted in-process: nothing reaches Sentry.
    func testShippedTelemetryResourceProducesAReporterThatTargetsItsDSN() throws {
        let shipped = SDKRuntimeConfiguration.load(environment: [:])
        let dsn = try XCTUnwrap(shipped.sentryDSN, "The bundled telemetry resource has no Sentry DSN.")
        let parsed = try XCTUnwrap(SentryDSN(dsn), "The bundled Sentry DSN does not parse.")
        let wire = SentryWire(exactHost: try XCTUnwrap(parsed.envelopeURL.host))
        wire.replyToEverything(.failure(.cannotConnectToHost))
        let runtime = SDKTelemetryRuntime(configuration: shipped, sentrySessionConfiguration: wire.sessionConfiguration())

        let reporter = SDKErrorReporterFactory.create(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_test_123"),
            sessionID: "session-uuid",
            flowType: "standard",
            runtime: runtime
        )
        XCTAssertTrue(reporter is IsolatedSentryErrorReporter)
        reporter.capture(operation: "resource_check", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first).request
        XCTAssertEqual(request.url, parsed.envelopeURL)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "X-Sentry-Auth")?.contains("sentry_key=\(parsed.publicKey)") == true
        )
    }

    func testOrderIDTagFallsBackToTheSubscriptionAndIsOmittedWithoutEither() throws {
        let subscriptionWire = SentryWire()
        let noIDWire = SentryWire()
        for (wire, config) in [
            (subscriptionWire, GlomoPayConfig(publicKey: "test_public_key", subscriptionId: "sub_test_9")),
            (noIDWire, GlomoPayConfig(publicKey: "test_public_key")),
        ] {
            let reporter = reporterFromConfiguration(
                environment: [:],
                bundled: ["GLOMOPAY_SENTRY_DSN": wire.dsn],
                sessionConfiguration: wire.sessionConfiguration(),
                config: config
            )
            reporter.capture(operation: "order_fetch", error: SyntheticError(), context: [:])
            reporter.flush(timeout: deliveryTimeout)
        }

        let subscriptionTags = try XCTUnwrap(subscriptionWire.requests.first).event()["tags"] as? [String: String]
        XCTAssertEqual(subscriptionTags?["order_id"], "sub_test_9")
        let noIDTags = try XCTUnwrap(noIDWire.requests.first).event()["tags"] as? [String: String]
        XCTAssertNotNil(noIDTags)
        XCTAssertNil(noIDTags?["order_id"])
    }

    // MARK: Event content

    func testEventCarriesTheReportedFailureTagsAndExtras() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire, flowType: "auto", devMode: false)

        reporter.updateFlowType("lrs")
        reporter.capture(
            operation: "order_fetch",
            error: SyntheticError(),
            context: ["status_code": 502, "source": "api"]
        )
        reporter.flush(timeout: deliveryTimeout)

        let event = try XCTUnwrap(wire.requests.first).event()
        XCTAssertEqual(event["level"] as? String, "error")
        XCTAssertEqual(event["logger"] as? String, "com.glomopay.sdk.ios")
        XCTAssertEqual(
            (event["message"] as? [String: Any])?["formatted"] as? String,
            "order_fetch failed (SyntheticError)"
        )
        XCTAssertEqual(event["tags"] as? [String: String], [
            "sdk_source": "glomo-ios-sdk",
            "operation": "order_fetch",
            "flow_type": "lrs",
            "dev_mode": "false",
        ])
        let extra = try XCTUnwrap(event["extra"] as? [String: Any])
        XCTAssertEqual(extra["session_id"] as? String, "session-uuid")
        XCTAssertEqual(extra["status_code"] as? Int, 502)
        XCTAssertEqual(extra["source"] as? String, "api")
        XCTAssertEqual(extra.count, 3)
    }

    func testEventReleaseAndEnvironmentAreTheGlomoSDKNotTheHostApp() throws {
        let wire = SentryWire()
        let client = try wire.makeClient(infoDictionary: [
            "CFBundleIdentifier": "com.example.merchant",
            "CFBundleShortVersionString": "3.2.1",
            "CFBundleVersion": "45",
        ])
        let reporter = IsolatedSentryErrorReporter(
            client: client,
            sessionID: "session-uuid",
            initialFlowType: "standard",
            devMode: true
        )

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let event = try XCTUnwrap(wire.requests.first).event()
        XCTAssertEqual(event["release"] as? String, "glomo-ios-sdk@\(GlomoPaySDKBuild.version)")
        XCTAssertEqual(event["environment"] as? String, "glomo-ios-sdk")
        XCTAssertNil(event["dist"])
        XCTAssertFalse(try XCTUnwrap(wire.requests.first).bodyText.contains("com.example.merchant"))
        XCTAssertEqual(event["platform"] as? String, "cocoa")
        let sdk = try XCTUnwrap(event["sdk"] as? [String: Any])
        XCTAssertEqual(sdk["name"] as? String, "glomo-ios-sdk")
        XCTAssertEqual(sdk["version"] as? String, GlomoPaySDKBuild.version)
        let app = (event["contexts"] as? [String: Any])?["app"] as? [String: String]
        XCTAssertEqual(app, ["app_version": "3.2.1", "app_build": "45"])
        XCTAssertEqual((event["tags"] as? [String: String])?["dev_mode"], "true")
        XCTAssertNotNil(event["timestamp"] as? Double)
    }

    func testOperationIsSanitisedAndTruncatedToEightyCharacters() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)
        let operation = "lookup someone@example.com " + String(repeating: "x", count: 200)

        reporter.capture(operation: operation, error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        let event = try request.event()
        let tag = try XCTUnwrap((event["tags"] as? [String: String])?["operation"])
        XCTAssertEqual(tag.count, 80)
        XCTAssertTrue(tag.hasPrefix("lookup [REDACTED] x"), tag)
        XCTAssertEqual(
            (event["message"] as? [String: Any])?["formatted"] as? String,
            "\(tag) failed (SyntheticError)"
        )
        XCTAssertFalse(request.bodyText.contains("someone@example.com"))
    }

    // MARK: Privacy

    func testContextOutsideTheAllowlistNeverReachesTheWire() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)
        let disallowed: [String: Any?] = [
            "order_id": "order_live_7f3a",
            "public_key": "live_pk_9b1c",
            "customer_email": "someone@example.com",
            "failed_url": "https://checkout.example.test/?orderId=order_live_7f3a",
            "amount": 125_000,
        ]

        reporter.addBreadcrumb(
            category: "checkout",
            message: "loaded",
            data: disallowed.merging(["webview_type": "main"]) { current, _ in current }
        )
        reporter.capture(
            operation: "load_checkout",
            error: SyntheticError(),
            context: disallowed.merging(["event_name": "checkout.error"]) { current, _ in current }
        )
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        for fragment in ["order_live_7f3a", "live_pk_9b1c", "someone@example.com", "customer_email",
                         "failed_url", "\"amount\"", "\"order_id\"", "\"public_key\""] {
            XCTAssertFalse(request.bodyText.contains(fragment), "\(fragment) reached the wire")
        }
        let event = try request.event()
        XCTAssertEqual((event["extra"] as? [String: Any])?["event_name"] as? String, "checkout.error")
        let crumb = try XCTUnwrap(((event["breadcrumbs"] as? [String: Any])?["values"] as? [[String: Any]])?.first)
        XCTAssertEqual(crumb["data"] as? [String: String], ["webview_type": "main"])
    }

    func testEventCarriesNoUserFieldsRequestIPOrStackTraceAndOptsOutOfIPStorage() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: ["source": "api"])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        let event = try request.event()
        for key in ["user", "request", "server_name", "threads", "exception", "debug_meta"] {
            XCTAssertNil(event[key], "\(key) was sent")
        }
        // No user object at all, so no user id, email, username, name or IP. `infer_ip` must be
        // `never`: left unset, Relay stored the connection IP for the Cocoa platform.
        for fragment in ["\"email\"", "username", "\"ip_address\"", "{{auto}}"] {
            XCTAssertFalse(request.bodyText.contains(fragment), "\(fragment) was sent")
        }
        let sdk = try XCTUnwrap(event["sdk"] as? [String: Any])
        XCTAssertEqual(Set(sdk.keys), ["name", "version", "settings"])
        XCTAssertEqual(sdk["settings"] as? [String: String], ["infer_ip": "never"])
        XCTAssertNil(request.request.value(forHTTPHeaderField: "Cookie"))
    }

    func testContextsCarryOnlyOSAndDeviceIdentity() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        let contexts = try XCTUnwrap(request.event()["contexts"] as? [String: Any])
        // No host info dictionary in this client, so there is no app context.
        XCTAssertEqual(Set(contexts.keys), ["os", "device"])

        // Each value is compared with the same fact read independently here, so the test fails if
        // collection breaks, not only if a literal changes.
        let os = try XCTUnwrap(contexts["os"] as? [String: Any])
        XCTAssertEqual(Set(os.keys), ["name", "version", "build"])
        XCTAssertEqual(os["build"] as? String, try XCTUnwrap(Self.sysctlString("kern.osversion")))
        let device = try XCTUnwrap(contexts["device"] as? [String: Any])
        XCTAssertEqual(Set(device.keys), ["model", "family", "simulator"])
        let model = try XCTUnwrap(device["model"] as? String)
        #if targetEnvironment(simulator)
        XCTAssertEqual(model, ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"])
        XCTAssertEqual(device["simulator"] as? Bool, true)
        #else
        XCTAssertEqual(model, Self.unameMachine())
        XCTAssertEqual(device["simulator"] as? Bool, false)
        #endif
        #if canImport(UIKit)
        XCTAssertEqual(os["version"] as? String, UIDevice.current.systemVersion)
        XCTAssertEqual(os["name"] as? String, "iOS")
        XCTAssertEqual(device["family"] as? String, UIDevice.current.model.hasPrefix("iPad") ? "iPad" : "iOS")
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expected = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        XCTAssertEqual(os["version"] as? String, expected)
        XCTAssertEqual(os["name"] as? String, "macOS")
        XCTAssertEqual(device["family"] as? String, "macOS")
        #endif
    }

    func testContextsNeverCarryIdentifyingOrVolatileDeviceData() throws {
        let wire = SentryWire()
        let client = try wire.makeClient(infoDictionary: [
            "CFBundleIdentifier": "com.example.merchant",
            "CFBundleName": "Merchant Wallet",
            "CFBundleDisplayName": "Merchant Wallet Display",
            "CFBundleShortVersionString": "3.2.1",
            "CFBundleVersion": "45",
        ])
        let reporter = IsolatedSentryErrorReporter(
            client: client,
            sessionID: "session-uuid",
            initialFlowType: "standard",
            devMode: false
        )

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        let contexts = try XCTUnwrap(request.event()["contexts"] as? [String: Any])
        XCTAssertEqual(Set(contexts.keys), ["os", "device", "app"])
        XCTAssertEqual(contexts["app"] as? [String: String], ["app_version": "3.2.1", "app_build": "45"])
        XCTAssertNil((contexts["device"] as? [String: Any])?["name"])
        for fragment in [
            "Merchant Wallet", "app_name", "app_identifier", "device_name", "identifierForVendor",
            "vendor_id", "advertising", "idfa", "ip_address", "locale", "timezone", "culture",
            "battery", "memory", "orientation", "thermal", "view_names", "charging", "storage",
        ] {
            XCTAssertFalse(request.bodyText.contains(fragment), "\(fragment) reached the wire")
        }
        let hostName = ProcessInfo.processInfo.hostName
        if hostName.count >= 8, hostName != "localhost" {
            XCTAssertFalse(request.bodyText.contains(hostName), "the machine's host name reached the wire")
        }
        // The host bundle id is not sent anywhere, not even inside `release`.
        XCTAssertFalse(request.bodyText.contains("com.example.merchant"))
        XCTAssertNil(try request.event()["dist"])
    }

    // MARK: Breadcrumbs

    func testBreadcrumbsAreSanitisedAndCappedAtThirtyDroppingTheOldest() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        for index in 0..<35 {
            reporter.addBreadcrumb(
                category: "checkout",
                message: "step \(index) for someone@example.com",
                data: ["source": "bridge"]
            )
        }
        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let event = try XCTUnwrap(wire.requests.first).event()
        let crumbs = try XCTUnwrap((event["breadcrumbs"] as? [String: Any])?["values"] as? [[String: Any]])
        XCTAssertEqual(crumbs.count, 30)
        XCTAssertEqual(crumbs.first?["message"] as? String, "step 5 for [REDACTED]")
        XCTAssertEqual(crumbs.last?["message"] as? String, "step 34 for [REDACTED]")
        XCTAssertEqual(crumbs.first?["level"] as? String, "info")
        XCTAssertEqual(crumbs.first?["category"] as? String, "checkout")
        XCTAssertNotNil(crumbs.first?["timestamp"] as? String)
    }

    func testBreadcrumbCategoryAndMessageAreTruncated() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        reporter.addBreadcrumb(
            category: String(repeating: "c", count: 120),
            message: String(repeating: "m", count: 400),
            data: [:]
        )
        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let event = try XCTUnwrap(wire.requests.first).event()
        let crumb = try XCTUnwrap(((event["breadcrumbs"] as? [String: Any])?["values"] as? [[String: Any]])?.first)
        XCTAssertEqual((crumb["category"] as? String)?.count, 80)
        XCTAssertEqual((crumb["message"] as? String)?.count, 200)
        XCTAssertNil(crumb["data"])
    }

    // MARK: Rate limiting

    func testRateLimitHeaderDropsEventsUntilTheWindowPasses() throws {
        let wire = SentryWire()
        let clock = TestClock()
        let reporter = try makeReporter(wire, now: { clock.now })
        wire.script(.status(200, headers: ["X-Sentry-Rate-Limits": "60:error:organization:quota"]))

        captureAndFlush(reporter, "first")
        captureAndFlush(reporter, "inside_window")
        clock.advance(by: 30)
        captureAndFlush(reporter, "still_inside_window")
        clock.advance(by: 31)
        captureAndFlush(reporter, "after_window")

        XCTAssertEqual(try operations(on: wire), ["first", "after_window"])
    }

    func testBare429HonoursRetryAfter() throws {
        let wire = SentryWire()
        let clock = TestClock()
        let reporter = try makeReporter(wire, now: { clock.now })
        wire.script(.status(429, headers: ["Retry-After": "30"]))

        captureAndFlush(reporter, "limited")
        captureAndFlush(reporter, "dropped")
        clock.advance(by: 31)
        captureAndFlush(reporter, "delivered")

        XCTAssertEqual(try operations(on: wire), ["limited", "delivered"])
    }

    func testBare429WithoutUsableHeadersStillBacksOff() throws {
        let wire = SentryWire()
        let clock = TestClock()
        let reporter = try makeReporter(wire, now: { clock.now })
        wire.script(.status(429, headers: ["Retry-After": "gibberish"]))

        captureAndFlush(reporter, "limited")
        captureAndFlush(reporter, "dropped")
        clock.advance(by: 61)
        captureAndFlush(reporter, "delivered")

        XCTAssertEqual(try operations(on: wire), ["limited", "delivered"])
    }

    func testRateLimitOnAnotherCategoryDoesNotDropEvents() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)
        wire.script(.status(200, headers: ["X-Sentry-Rate-Limits": "600:transaction;session:organization"]))

        captureAndFlush(reporter, "first")
        captureAndFlush(reporter, "second")

        XCTAssertEqual(try operations(on: wire), ["first", "second"])
    }

    func testRateLimitWithNoCategoriesDropsEverything() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)
        wire.script(.status(200, headers: ["X-Sentry-Rate-Limits": "2700.0::organization"]))

        captureAndFlush(reporter, "first")
        captureAndFlush(reporter, "dropped")

        XCTAssertEqual(try operations(on: wire), ["first"])
    }

    // MARK: Failure isolation

    func testServerErrorsAndNetworkFailuresAreNotRetriedAndDoNotStopLaterEvents() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)
        wire.script(.status(503), .failure(.notConnectedToInternet), .status(500), .failure(.timedOut))

        for operation in ["server_error", "offline", "internal_error", "timeout", "healthy"] {
            captureAndFlush(reporter, operation)
        }

        XCTAssertEqual(
            try operations(on: wire),
            ["server_error", "offline", "internal_error", "timeout", "healthy"]
        )
    }

    func testCaptureReportsWhatHappenedToEachSend() throws {
        let wire = SentryWire()
        let client = try wire.makeClient()
        wire.script(.status(200), .failure(.notConnectedToInternet), .status(429, headers: ["Retry-After": "60"]))
        let recorder = OutcomeRecorder()

        for _ in 0..<4 {
            let done = expectation(description: "outcome")
            client.capture(event: ["level": "error"]) { outcome in
                recorder.append(outcome)
                done.fulfill()
            }
            wait(for: [done], timeout: deliveryTimeout)
        }

        let eventIDs = try wire.requests.map { try XCTUnwrap($0.envelopeHeader()["event_id"] as? String) }
        XCTAssertEqual(eventIDs.count, 3)
        XCTAssertEqual(recorder.outcomes, [
            .responded(eventID: eventIDs[0], statusCode: 200),
            .failed(eventID: eventIDs[1]),
            .responded(eventID: eventIDs[2], statusCode: 429),
            .dropped,
        ])
    }

    // MARK: Dropped-event self-reporting

    func testDroppedEventsAreReportedOnTheNextAcceptedEventAndClearedAfterIt() throws {
        let wire = SentryWire()
        let clock = TestClock()
        let reporter = try makeReporter(wire, now: { clock.now })
        wire.script(.status(503), .failure(.notConnectedToInternet), .status(429, headers: ["Retry-After": "30"]))

        captureAndFlush(reporter, "server_error")   // 503: 1 dropped
        captureAndFlush(reporter, "offline")        // carries 1, fails: 2 dropped
        captureAndFlush(reporter, "limited")        // carries 2, 429: 3 dropped
        captureAndFlush(reporter, "rate_limited")   // never sent: 4 dropped
        clock.advance(by: 31)
        captureAndFlush(reporter, "accepted")       // carries 4, 200: cleared
        captureAndFlush(reporter, "clean")

        XCTAssertEqual(try operations(on: wire), ["server_error", "offline", "limited", "accepted", "clean"])
        XCTAssertEqual(try droppedCounts(on: wire), [nil, 1, 2, 4, nil])
    }

    func testEventsRejectedByTheInFlightBoundAreCounted() throws {
        let wire = SentryWire()
        wire.replyToEverything(.held)
        let reporter = try makeReporter(wire)
        let overflow = 3

        for index in 0..<(SentryEnvelopeClient.maxInFlight + overflow) {
            reporter.capture(operation: "burst_\(index)", error: SyntheticError(), context: [:])
        }
        wire.release()
        reporter.flush(timeout: deliveryTimeout)
        captureAndFlush(reporter, "after_burst")
        captureAndFlush(reporter, "clean")

        // The rejections may be picked up by a burst send still queued, or by the next one; either
        // way each is reported exactly once.
        let counts = try droppedCounts(on: wire)
        XCTAssertEqual(counts.compactMap { $0 }.reduce(0, +), overflow)
        XCTAssertNil(counts.last ?? nil)
    }

    // MARK: Compression

    func testBodyIsGzipAndDecompressesToTheEnvelope() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)
        for index in 0..<30 {
            reporter.addBreadcrumb(category: "checkout", message: "step \(index) ₹ भुगतान", data: ["source": "bridge"])
        }

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(Array(request.wireBody.prefix(3)), [0x1F, 0x8B, 0x08])
        XCTAssertEqual(SentryWire.gunzip(request.wireBody), request.body)
        XCTAssertLessThan(request.wireBody.count, request.body.count / 2)
        // The item length describes the uncompressed item, not the HTTP body.
        XCTAssertEqual(try request.itemHeader()["length"] as? Int, request.lines[2].count)
    }

    func testCaptureReturnsWithoutWaitingForTheNetwork() throws {
        let wire = SentryWire()
        wire.replyToEverything(.held)
        let reporter = try makeReporter(wire)
        defer { wire.release() }

        let started = Date()
        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testFlushWaitsForAnInFlightSend() throws {
        let wire = SentryWire()
        wire.replyToEverything(.held)
        let reporter = try makeReporter(wire)

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { wire.release() }
        let started = Date()
        reporter.flush(timeout: deliveryTimeout)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, deliveryTimeout)
        XCTAssertEqual(wire.requests.count, 1)
    }

    func testFlushReturnsWithinItsTimeoutWhenASendHangs() throws {
        let wire = SentryWire()
        wire.replyToEverything(.held)
        let reporter = try makeReporter(wire)
        defer { wire.release() }

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: [:])
        let started = Date()
        reporter.flush(timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        XCTAssertLessThan(elapsed, 3)
    }

    func testEventsBeyondTheInFlightBoundAreDroppedNotQueued() throws {
        let wire = SentryWire()
        wire.replyToEverything(.held)
        let reporter = try makeReporter(wire)
        let bound = SentryEnvelopeClient.maxInFlight

        for index in 0..<(bound + 5) {
            reporter.capture(operation: "burst_\(index)", error: SyntheticError(), context: [:])
        }
        wire.release()
        reporter.flush(timeout: deliveryTimeout)
        // A later event is accepted once the backlog has drained.
        captureAndFlush(reporter, "after_burst")

        XCTAssertEqual(wire.requests.count, bound + 1)
        XCTAssertEqual(try operations(on: wire).last, "after_burst")
    }

    func testNonFiniteContextNumbersAreDroppedInsteadOfCrashing() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        reporter.capture(
            operation: "load_checkout",
            error: SyntheticError(),
            context: ["status_code": Double.nan, "source": Double.infinity, "event_name": "still_sent"]
        )
        reporter.flush(timeout: deliveryTimeout)

        let extra = try XCTUnwrap(wire.requests.first).event()["extra"] as? [String: Any]
        XCTAssertEqual(extra?["event_name"] as? String, "still_sent")
        XCTAssertNil(extra?["status_code"])
        XCTAssertNil(extra?["source"])
    }

    // MARK: Helpers

    private func makeReporter(
        _ wire: SentryWire,
        flowType: String = "standard",
        devMode: Bool = false,
        now: @escaping () -> Date = Date.init
    ) throws -> IsolatedSentryErrorReporter {
        IsolatedSentryErrorReporter(
            client: try wire.makeClient(now: now),
            sessionID: "session-uuid",
            initialFlowType: flowType,
            devMode: devMode
        )
    }

    private func reporterFromConfiguration(
        environment: [String: String],
        bundled: [String: String],
        sessionConfiguration: URLSessionConfiguration = SentryEnvelopeClient.defaultSessionConfiguration(),
        config: GlomoPayConfig = GlomoPayConfig(publicKey: "test_public_key", orderId: "order_test_123"),
        flowType: String = "standard"
    ) -> SDKErrorReporting {
        let runtime = SDKTelemetryRuntime(
            configuration: SDKRuntimeConfiguration.load(environment: environment, bundledValues: bundled),
            sentrySessionConfiguration: sessionConfiguration
        )
        return SDKErrorReporterFactory.create(
            config: config,
            sessionID: "session-uuid",
            flowType: flowType,
            runtime: runtime
        )
    }

    private func droppedCounts(on wire: SentryWire) throws -> [Int?] {
        try wire.requests.map { request in
            (try request.event()["extra"] as? [String: Any])?["dropped_since_last_send"] as? Int
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func unameMachine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func captureAndFlush(_ reporter: IsolatedSentryErrorReporter, _ operation: String) {
        reporter.capture(operation: operation, error: SyntheticError(), context: [:])
        reporter.flush(timeout: deliveryTimeout)
    }

    private func operations(on wire: SentryWire) throws -> [String] {
        try wire.requests.map { request in
            try XCTUnwrap((request.event()["tags"] as? [String: String])?["operation"])
        }
    }
}

private struct SyntheticError: Error {}

private final class OutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SentrySendOutcome] = []

    var outcomes: [SentrySendOutcome] { lock.glomoWithLock { recorded } }

    func append(_ outcome: SentrySendOutcome) {
        lock.glomoWithLock { recorded.append(outcome) }
    }
}
