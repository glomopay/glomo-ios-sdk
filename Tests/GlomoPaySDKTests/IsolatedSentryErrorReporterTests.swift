import XCTest
@testable import GlomoPaySDK

/// Behaviour of SDK error reporting as observed on the wire. See `SentryWire` for why requests
/// are intercepted at the `URLSession` boundary rather than by substituting SDK types.
final class IsolatedSentryErrorReporterTests: XCTestCase {
    private let deliveryTimeout: TimeInterval = 10

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
        XCTAssertTrue(auth.contains("sentry_client=sentry.cocoa/9.19.1"), auth)
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

    func testBlankOrMalformedDSNTurnsErrorReportingOff() {
        let unusable = [
            "",
            "   ",
            "not a dsn",
            "ftp://key@example.test/1",
            "https://example.test/1",
            "https://key@example.test",
            "https://key@example.test/",
            "https://key@/1",
        ]

        for dsn in unusable {
            XCTAssertNil(SentryEnvelopeClient(dsn: dsn), dsn)
            let runtime = SDKTelemetryRuntime(
                configuration: SDKRuntimeConfiguration(mixpanelToken: nil, sentryDSN: dsn)
            )
            let reporter = SDKErrorReporterFactory.create(
                config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
                sessionID: "session-uuid",
                flowType: "standard",
                runtime: runtime
            )
            XCTAssertTrue(reporter is NoOpSDKErrorReporter, dsn)
        }
    }

    func testUsableDSNTurnsErrorReportingOn() {
        let runtime = SDKTelemetryRuntime(
            configuration: SDKRuntimeConfiguration(
                mixpanelToken: nil,
                sentryDSN: " https://fakepublickey@o1.ingest.example.test/42 "
            )
        )

        let reporter = SDKErrorReporterFactory.create(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123"),
            sessionID: "session-uuid",
            flowType: "standard",
            runtime: runtime
        )

        XCTAssertTrue(reporter is IsolatedSentryErrorReporter)
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

    func testEventIdentifiesTheHostReleaseLikeTheSentryCocoaDefaults() throws {
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
        XCTAssertEqual(event["release"] as? String, "com.example.merchant@3.2.1+45")
        XCTAssertEqual(event["dist"] as? String, "45")
        XCTAssertEqual(event["environment"] as? String, "production")
        XCTAssertEqual(event["platform"] as? String, "cocoa")
        let sdk = try XCTUnwrap(event["sdk"] as? [String: Any])
        XCTAssertEqual(sdk["name"] as? String, "sentry.cocoa")
        XCTAssertEqual(sdk["version"] as? String, "9.19.1")
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

    func testEventCarriesNoUserRequestIPOrStackTrace() throws {
        let wire = SentryWire()
        let reporter = try makeReporter(wire)

        reporter.capture(operation: "load_checkout", error: SyntheticError(), context: ["source": "api"])
        reporter.flush(timeout: deliveryTimeout)

        let request = try XCTUnwrap(wire.requests.first)
        let event = try request.event()
        for key in ["user", "request", "contexts", "server_name", "threads", "exception", "debug_meta"] {
            XCTAssertNil(event[key], "\(key) was sent")
        }
        XCTAssertFalse(request.bodyText.contains("ip_address"))
        XCTAssertFalse(request.bodyText.contains("{{auto}}"))
        let settings = (event["sdk"] as? [String: Any])?["settings"] as? [String: String]
        XCTAssertEqual(settings, ["infer_ip": "never"])
        XCTAssertNil(request.request.value(forHTTPHeaderField: "Cookie"))
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
