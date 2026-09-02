import XCTest
import UniformTypeIdentifiers
@testable import GlomoPaySDK

final class AnalyticsEventRoutingTests: XCTestCase {
    func testPaymentAndEducationBridgeMessagesTrackExpectedEvents() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
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
        router.handle(envelope: [
            "type": "message",
            "data": ["type": "lrs.has_education_steps", "value": true],
        ])

        XCTAssertEqual(analytics.events.map(\.name), [
            AnalyticsEventName.paymentPending,
            AnalyticsEventName.educationStepsShown,
        ])
    }

    func testMalformedMessageTracksInvalidMessageAndSDKError() throws {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(body: "not-json")

        XCTAssertEqual(analytics.events.map(\.name), [
            AnalyticsEventName.invalidMessageReceived,
            AnalyticsEventName.sdkError,
        ])
        let invalidMessage = try XCTUnwrap(analytics.events.first)
        XCTAssertFalse(invalidMessage.properties.keys.contains("data"))
        XCTAssertEqual(invalidMessage.properties["data_type"] as? String, "String")
        XCTAssertEqual(invalidMessage.properties["top_level_keys"] as? String, "")
        XCTAssertEqual(invalidMessage.properties["byte_length"] as? Int, 8)
    }

    func testSchemaKeyFilteringDropsSensitiveFieldNames() {
        XCTAssertEqual(
            AnalyticsSanitizer.schemaKeys(["type", "payment_id", "customer_email", "card_number"]),
            ["payment_id", "type"]
        )
    }

    func testSDKErrorSerializationEscapesMessagesAndPreservesShape() throws {
        let message = "Invalid fragment: {\"type\":\"a\"}\\next\nline"
        let serialized = SDKErrorAnalyticsSerializer.serialize([
            SdkError(type: .unknown, message: message, field: "bridge"),
        ])
        let data = try XCTUnwrap(serialized.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let error = try XCTUnwrap(payload.first)

        XCTAssertEqual(error["type"] as? String, "unknown")
        XCTAssertEqual(error["message"] as? String, message)
        XCTAssertEqual(error["field"] as? String, "bridge")
    }

    func testUnknownBridgeMessageTracksUnsupportedFunctionality() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: ["type": "merchant.unsupported_action"])

        XCTAssertEqual(analytics.events.last?.name, AnalyticsEventName.unsupportedFunctionalityUsed)
        XCTAssertEqual(analytics.events.last?.properties["name"] as? String, "merchant.unsupported_action")
    }

    func testFileInputStoresRequestedAcceptTypesForNativePicker() {
        let analytics = RecordingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "file.input",
            "accept": " application/pdf, image/* ",
        ])

        XCTAssertEqual(router.latestFileAcceptTypes, "application/pdf, image/*")
        XCTAssertEqual(
            analytics.events.last?.properties["accept_types"] as? String,
            "application/pdf, image/*"
        )
    }

    @available(macOS 11.0, *)
    func testFileAcceptTypesResolveMIMEsExtensionsAndFallback() {
        let resolved = FileAcceptTypeResolver.contentTypes(
            for: "application/pdf, image/*, .heic, application/pdf"
        )

        XCTAssertTrue(resolved.contains(where: { $0.conforms(to: .pdf) }))
        XCTAssertTrue(resolved.contains(where: { $0.conforms(to: .image) }))
        XCTAssertEqual(resolved.filter { $0.conforms(to: .pdf) }.count, 1)
        XCTAssertEqual(FileAcceptTypeResolver.contentTypes(for: "").map(\.identifier), [UTType.item.identifier])
        XCTAssertEqual(
            FileAcceptTypeResolver.contentTypes(for: "not-a-valid-type").map(\.identifier),
            [UTType.item.identifier]
        )
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
            let trackPattern = #"\.track\s*\(\s*AnalyticsEventName\."# + escapedIdentifier + #"\b"#
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

private final class RecordingAnalyticsTracker: AnalyticsTracking {
    struct RecordedEvent { let name: String; let properties: [String: Any?] }
    var events: [RecordedEvent] = []
    func track(_ event: String, properties: [String: Any?]) {
        events.append(RecordedEvent(name: event, properties: properties))
    }
    func updateFlowType(_ flowType: String) {}
    func updateCheckoutURL(_ url: URL) {}
}
