import XCTest
@testable import GlomoPaySDK

final class AnalyticsSanitizerTests: XCTestCase {
    func testSharedFixture() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 27)

        for fixtureCase in cases {
            let name = fixtureCase["name"] as? String ?? "unnamed"
            let key = try XCTUnwrap(fixtureCase["key"] as? String, name)
            let value = try XCTUnwrap(fixtureCase["value"], name)

            let output = AnalyticsSanitizer.properties([key: value])

            if fixtureCase["absent"] as? Bool == true {
                XCTAssertNil(output[key], name)
            } else {
                XCTAssertEqual(try jsonText(output[key]), try jsonText(fixtureCase["expected"]), name)
            }
        }
    }

    func testBankRedirectKeepsOnlyHTTPSOrigin() {
        let url = URL(string: "https://user:pass@3DS.IN.Secure.Bank.COM:8443/verify/ABCDE1234F?phone=9876543210#otp")!

        XCTAssertEqual(AnalyticsSanitizer.bankRedirectURL(url), "https://3ds.in.secure.bank.com")
        XCTAssertNil(AnalyticsSanitizer.bankRedirectURL(URL(string: "http://bank.example/otp")))
    }

    func testURLOriginDropsPathQueryAndCredentials() {
        let url = URL(string: "https://user:pass@Checkout.Example.com:8443/order_123?publicKey=live_pk_1#x")!

        XCTAssertEqual(AnalyticsSanitizer.urlOrigin(url), "https://checkout.example.com:8443")
        XCTAssertNil(AnalyticsSanitizer.urlOrigin(URL(string: "upi://pay?pa=someone@bank")))
    }

    func testSensitiveKeysAreMaskedWhileOpaqueGlomoIdentifiersRemain() {
        let output = AnalyticsSanitizer.properties([
            "resource_id": "order_6af743563",
            "customer_email": "user@example.com",
        ])

        XCTAssertEqual(output["resource_id"] as? String, "order_6af743563")
        XCTAssertEqual(output["customer_email"] as? String, "•••")
    }

    func testKnownFailingUUIDRoundTripsWithoutPartialRedaction() {
        let uuid = "01d245ac-f936-4545-9013-7114243e312f"
        let output = AnalyticsSanitizer.properties([
            "journey_id": uuid,
            "distinct_id": uuid,
            "request_id": uuid,
        ])

        XCTAssertEqual(output["journey_id"] as? String, uuid)
        XCTAssertEqual(output["distinct_id"] as? String, uuid)
        XCTAssertEqual(output["request_id"] as? String, uuid)
    }

    func testJourneyIdentityFieldsLeaveTheSanitizerUnchanged() {
        let uuid = "01d245ac-f936-4545-9013-7114243e312f"
        let output = AnalyticsSanitizer.properties([
            "journey_id": uuid,
            "$device_id": uuid,
            "distinct_id": "$device:\(uuid)",
        ])

        XCTAssertEqual(output["journey_id"] as? String, uuid)
        XCTAssertEqual(output["$device_id"] as? String, uuid)
        XCTAssertEqual(output["distinct_id"] as? String, "$device:\(uuid)")
    }

    func testStructuredSensitiveWholeValuesAreMaskedInsteadOfDropped() {
        let output = AnalyticsSanitizer.properties([
            "value_one": "user@example.com",
            "value_two": "9876543210",
            "value_three": "ABCDE1234F",
        ])

        XCTAssertEqual(output["value_one"] as? String, "u•••@example.com")
        XCTAssertEqual(output["value_two"] as? String, "••••3210")
        XCTAssertEqual(output["value_three"] as? String, "XXXXXX234F")
    }

    func testSentryFreeTextRedactionIsUnchanged() {
        let input = "user@example.com 9876543210 ABCDE1234F N1234567 ABC1234567"

        XCTAssertEqual(
            SentryScrubber.text(input, limit: 1_000),
            "[REDACTED] [REDACTED] [REDACTED] [REDACTED] [REDACTED]"
        )
    }

    func testTimestampLikeValuesAreNotMaskedAsNumericPII() {
        let timestamp = "2026-08-17T14:33:19.153+05:30"
        let output = AnalyticsSanitizer.properties(["occurred_at": timestamp])

        XCTAssertEqual(output["occurred_at"] as? String, timestamp)
    }

    func testNumericStatusKeepsItsMixpanelTypeAndValue() {
        let output = AnalyticsSanitizer.properties(["http_status": 502, "error_code": 123_456])

        XCTAssertEqual(output["http_status"] as? Int, 502)
        XCTAssertEqual(output["error_code"] as? Int, 123_456)
    }

    func testJSONNumbersAreNotCollapsedToBooleans() {
        let output = AnalyticsSanitizer.properties([
            "retry_count": NSNumber(value: 1),
            "enabled": NSNumber(value: true),
        ])

        XCTAssertEqual(output["retry_count"] as? Int, 1)
        XCTAssertFalse(output["retry_count"] is Bool)
        XCTAssertEqual(output["enabled"] as? Bool, true)
    }

    func testSensitiveSubstringsInsideStringValuesAreMasked() {
        let output = AnalyticsSanitizer.properties([
            "error_detail": "Card 4111 1111 1111 1111 declined for someone@example.com (PAN ABCDE1234F)",
            "failure_reason": "otp sent to 98765 43210",
        ])

        XCTAssertEqual(
            output["error_detail"] as? String,
            "Card XXXX-XXXX-XXXX-1111 declined for s•••@example.com (PAN XXXXXX234F)"
        )
        XCTAssertEqual(output["failure_reason"] as? String, "otp sent to ••••3210")
    }

    func testIdentifierAndJoinFieldsComeThroughVerbatim() {
        let input: [String: Any?] = [
            "resource_id": "order_6af743563",
            "journey_id": "01d245ac-f936-4545-9013-7114243e312f",
            "distinct_id": "$device:01d245ac-f936-4545-9013-7114243e312f",
            "$insert_id": "c1a9e4a2-3b51-4d3c-8b2e-123456789012",
            "payment_id": "pay_1234567890",
        ]

        let output = AnalyticsSanitizer.properties(input)

        for (key, value) in input {
            XCTAssertEqual(output[key] as? String, value as? String, key)
        }
    }

    func testPublicKeyAndSDKVersionGoThroughValueMasking() {
        let output = AnalyticsSanitizer.properties([
            "public_key": "live_pk_1234567890abcdef someone@example.com",
            "sdk_version": "1.0.0 build 9876543210",
        ])

        XCTAssertEqual(output["public_key"] as? String, "live_pk_1234567890abcdef s•••@example.com")
        XCTAssertEqual(output["sdk_version"] as? String, "1.0.0 build ••••3210")
    }

    func testIdentifierValuesAreCappedAtOneThousandCharacters() {
        let longID = "order_" + String(repeating: "a", count: 1_994)
        let output = AnalyticsSanitizer.properties([
            "resource_id": longID,
            "journey_id": String(repeating: "b", count: 2_000),
        ])

        XCTAssertEqual(output["resource_id"] as? String, String(longID.prefix(1_000)))
        XCTAssertEqual((output["journey_id"] as? String)?.count, 1_000)
    }

    func testDeviceAndHostAppMetadataIsNotRewrittenByMasking() {
        let input: [String: Any?] = [
            "$app_version_string": "1.4.0-20261001",
            "$app_build_number": "2026.10.01.123456",
            "$app_name": "Wallet (1234567)",
            "$app_namespace": "com.merchant.app",
            "$model": "iPhone15,2",
            "$os_version": "17.4.1",
            "$lib_version": "1.0.0",
        ]

        let output = AnalyticsSanitizer.properties(input)

        for (key, value) in input {
            XCTAssertEqual(output[key] as? String, value as? String, key)
        }
    }

    func testStringValuesAreStillCappedAtOneThousandCharacters() {
        let output = AnalyticsSanitizer.properties([
            "plain": String(repeating: "a", count: 1_500),
            "error_detail": "someone@example.com " + String(repeating: "b", count: 1_500),
        ])

        XCTAssertEqual((output["plain"] as? String)?.count, 1_000)
        let masked = output["error_detail"] as? String
        XCTAssertEqual(masked?.count, 1_000)
        XCTAssertEqual(masked?.hasPrefix("s•••@example.com bbb"), true)
    }

    func testNilValuesArePreservedAsNull() {
        let output = AnalyticsSanitizer.properties(["is_recoverable": nil])

        XCTAssertTrue(output["is_recoverable"] is NSNull)
    }

    private func jsonText(_ value: Any?) throws -> String {
        guard let value else { return "<absent>" }
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/analytics-sanitizer-fixture.json")
    }
}
