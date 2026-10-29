import XCTest

@testable import GlomoPaySDK

final class AnalyticsEventRoutingTests: XCTestCase {
    func testPendingIsNotTrackedAndOnlyTheEducationSignalIsAPageView() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.pending",
                "payload": ["orderId": "order_123", "paymentId": "pay_123"],
            ],
        ])
        for notSignal: [String: Any] in [
            ["type": "lrs.has_education_steps", "value": false],
            ["type": "lrs.has_education_steps", "hasContent": true],
            ["event": "lrs.has_education_steps", "hasContent": true],
        ] {
            router.handle(envelope: ["type": "message", "data": notSignal])
        }
        XCTAssertTrue(analytics.events.isEmpty)

        router.handle(envelope: [
            "type": "message",
            "data": ["type": "lrs.has_education_steps", "value": true],
        ])

        XCTAssertEqual(analytics.events.map(\.name), [AnalyticsEventName.sdkPageViewed])
        XCTAssertEqual(analytics.events.last?.properties["page_name"] as? String, "education_carousel")
    }

    func testEducationFailureKeepsTheFixedReasonListAndFallsBackForFreeText() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: ["type": "message", "data": ["type": "lrs.education_steps_failed"]])
        router.handle(envelope: [
            "type": "message",
            "data": ["type": "lrs.education_steps_failed", "reason": "webview_error"],
        ])
        router.handle(envelope: [
            "type": "message",
            "data": ["type": "lrs.education_steps_failed_to_show", "reason": "Customer someone@example.com"],
        ])

        XCTAssertEqual(analytics.events.map(\.name), Array(repeating: AnalyticsEventName.sdkActionFailed, count: 3))
        XCTAssertEqual(
            analytics.events.map { $0.properties["error_code"] as? String },
            ["render_failed", "webview_error", "other"]
        )
        XCTAssertTrue(analytics.events.allSatisfy { $0.properties["action_name"] as? String == "education_carousel" })
    }

    func testMalformedMessageIsNotAnAnalyticsEvent() {
        let analytics = RecordingAnalyticsTracker()
        let reporter = RecordingSDKErrorReporter()
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: reporter
        )

        router.handle(body: "not-json")

        XCTAssertTrue(analytics.events.isEmpty)
        XCTAssertEqual(reporter.operations, ["bridge_message", "listener_unavailable"])
    }

    func testSchemaKeyFilteringDropsSensitiveFieldNames() {
        XCTAssertEqual(
            SentryScrubber.schemaKeys(["type", "payment_id", "customer_email", "card_number"]),
            ["payment_id", "type"]
        )
    }

    func testUnroutedBridgeMessagesAreNotTracked() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: ["type": "merchant.unsupported_action"])
        router.handle(envelope: ["type": "file.input", "accept": "application/pdf"])
        router.handle(envelope: ["type": "console", "level": "log", "message": "hello"])
        router.handle(envelope: ["type": "message", "data": ["type": "merchant.custom_event"]])

        XCTAssertTrue(analytics.events.isEmpty)
    }

    func testInvalidSuccessPayloadIsADroppedPaymentPayload() {
        let analytics = RecordingAnalyticsTracker()
        var results: [GlomoPayResult] = []
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { results.append($0) },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "message",
            "data": ["type": "payment.success", "payload": ["orderId": "order_123456"]],
        ])

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(analytics.events.map(\.name), [AnalyticsEventName.sdkActionFailed])
        let properties = analytics.events.first?.properties ?? [:]
        XCTAssertEqual(properties["action_name"] as? String, "payment_payload")
        XCTAssertEqual(properties["error_code"] as? String, "dropped")
        XCTAssertEqual(properties["page_event"] as? String, "payment_success")
    }

    func testOutcomesAreNotPaymentEventsInTheRouter() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": ["orderId": "order_123456", "paymentId": "pay_123456", "signature": "signed"],
            ],
        ])

        XCTAssertTrue(analytics.events.isEmpty)
    }

    func testWindowOpenRejectsNonHTTPURLsAndReportsTheContractBreak() {
        let analytics = RecordingAnalyticsTracker()
        let reporter = RecordingSDKErrorReporter()
        var opened: [URL] = []
        let router = GlomoPayEventRouter(
            listener: nil,
            onComplete: { _ in },
            onWindowOpen: { opened.append($0) },
            analytics: analytics,
            errorReporter: reporter
        )

        for rawURL in [
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>",
            "file:///etc/passwd",
            "about:blank",
            "upi://pay",
            "https://",
            "https://user:pass@bank.example",
        ] {
            router.handle(envelope: ["type": "window.open", "url": rawURL])
        }
        router.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds?otp=123456"])

        XCTAssertEqual(opened.map(\.absoluteString), ["https://bank.example/3ds?otp=123456"])
        XCTAssertEqual(reporter.operations.filter { $0 == "window_open_rejected" }.count, 7)
        let failures = analytics.events.filter { $0.name == AnalyticsEventName.sdkActionFailed }
        XCTAssertEqual(failures.count, 7)
        XCTAssertTrue(failures.allSatisfy {
            $0.properties["action_name"] as? String == "navigation"
                && $0.properties["error_code"] as? String == "invalid_window_open_url"
                && $0.properties["webview_type"] as? String == "main"
        })
        let pageView = analytics.events.last
        XCTAssertEqual(pageView?.name, AnalyticsEventName.sdkPageViewed)
        XCTAssertEqual(pageView?.properties["page_name"] as? String, "bank_redirect")
        XCTAssertEqual(pageView?.properties["url_origin"] as? String, "https://bank.example")
    }

    func testEveryDeclaredAnalyticsEventHasATrackCallSite() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = repositoryRoot.appendingPathComponent("Sources/GlomoPaySDK")
        let trackerURL = sourcesRoot.appendingPathComponent("Analytics/AnalyticsTracker.swift")
        let trackerSource = try String(contentsOf: trackerURL, encoding: .utf8)

        guard let eventBlock = trackerSource
            .components(separatedBy: "enum AnalyticsEventName {")
            .dropFirst()
            .first?
            .components(separatedBy: "\n}\n\n")
            .first else {
            return XCTFail("Unable to locate AnalyticsEventName declarations")
        }

        let declarationPattern = #"(?m)^\s+static let ([A-Za-z][A-Za-z0-9_]*)\s*="#
        let expression = try NSRegularExpression(pattern: declarationPattern)
        let range = NSRange(eventBlock.startIndex..<eventBlock.endIndex, in: eventBlock)
        let identifiers = expression.matches(in: eventBlock, range: range).compactMap { match -> String? in
            guard let identifierRange = Range(match.range(at: 1), in: eventBlock) else { return nil }
            return String(eventBlock[identifierRange])
        }

        let source = try swiftSource(in: sourcesRoot, excluding: trackerURL)
        let missingCallSites = identifiers.filter { identifier in
            let escapedIdentifier = NSRegularExpression.escapedPattern(for: identifier)
            let trackPattern = #"(?<![A-Za-z0-9_])track\s*\(\s*AnalyticsEventName\."# + escapedIdentifier + #"\b"#
            return source.range(of: trackPattern, options: .regularExpression) == nil
        }

        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertEqual(missingCallSites, [], "Events without track call sites: \(missingCallSites)")
    }

    private func swiftSource(in directory: URL, excluding excludedURL: URL) throws -> String {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys)
        ) else {
            throw NSError(domain: "AnalyticsEventRoutingTests", code: 1)
        }

        return try enumerator.compactMap { item -> String? in
            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  url.standardizedFileURL != excludedURL.standardizedFileURL,
                  try url.resourceValues(forKeys: resourceKeys).isRegularFile == true else {
                return nil
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
    }
}

private final class RecordingSDKErrorReporter: SDKErrorReporting, @unchecked Sendable {
    var operations: [String] = []
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) {
        operations.append(operation)
    }
}

private final class RecordingAnalyticsTracker: AnalyticsTracking {
    struct RecordedEvent { let name: String; let properties: [String: Any?] }
    var events: [RecordedEvent] = []
    func track(_ event: String, properties: [String: Any?]) {
        events.append(RecordedEvent(name: event, properties: properties))
    }
    func updateFlowType(_ flowType: String) {}
}
