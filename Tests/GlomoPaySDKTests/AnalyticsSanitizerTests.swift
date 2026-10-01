import XCTest
@testable import GlomoPaySDK

final class AnalyticsSanitizerTests: XCTestCase {
    func testBankRedirectKeepsOnlyHTTPSOrigin() {
        let url = URL(string: "https://user:pass@3DS.IN.Secure.Bank.COM:8443/verify/ABCDE1234F?phone=9876543210#otp")!

        XCTAssertEqual(AnalyticsSanitizer.bankRedirectURL(url), "https://3ds.in.secure.bank.com")
        XCTAssertNil(AnalyticsSanitizer.bankRedirectURL(URL(string: "http://bank.example/otp")))
    }

    func testBlockedPIIKeysAreDroppedWhileOpaqueGlomoIdentifiersRemain() {
        let output = AnalyticsSanitizer.properties([
            "order_id": "order_6af743563",
            "customer_email": "user@example.com",
        ])

        XCTAssertEqual(output["order_id"] as? String, "order_6af743563")
        XCTAssertNil(output["customer_email"])
    }

    func testKnownFailingUUIDRoundTripsWithoutPartialRedaction() {
        let uuid = "01d245ac-f936-4545-9013-7114243e312f"
        let output = AnalyticsSanitizer.properties([
            "session_id": uuid,
            "distinct_id": uuid,
        ])

        XCTAssertEqual(output["session_id"] as? String, uuid)
        XCTAssertEqual(output["distinct_id"] as? String, uuid)
    }

    func testStructuredSensitiveWholeValuesAreDroppedInsteadOfRewritten() {
        let output = AnalyticsSanitizer.properties([
            "value_one": "user@example.com",
            "value_two": "9876543210",
            "value_three": "ABCDE1234F",
        ])

        XCTAssertNil(output["value_one"])
        XCTAssertNil(output["value_two"])
        XCTAssertNil(output["value_three"])
    }

    func testStructuredUUIDValueIsNotPartiallyRewritten() {
        let uuid = "01d245ac-f936-4545-9013-7114243e312f"
        let output = AnalyticsSanitizer.properties(["request_id": uuid])

        XCTAssertEqual(output["request_id"] as? String, uuid)
    }

    func testFreeTextStillRedactsSensitiveSubstrings() {
        let input = "user@example.com 9876543210 ABCDE1234F N1234567 ABC1234567"

        XCTAssertEqual(
            AnalyticsSanitizer.text(input, limit: 1_000),
            "[REDACTED] [REDACTED] [REDACTED] [REDACTED] [REDACTED]"
        )
    }

    func testTimestampIsNotRedactedAsNumericPII() {
        let timestamp = "2026-08-17T14:33:19.153+05:30"
        let output = AnalyticsSanitizer.properties(["timestamp": timestamp])

        XCTAssertEqual(output["timestamp"] as? String, timestamp)
    }

    func testNumericErrorCodeKeepsItsMixpanelTypeAndValue() {
        let output = AnalyticsSanitizer.properties(["error_code": 123_456])

        XCTAssertEqual(output["error_code"] as? Int, 123_456)
    }

    func testJSONNumbersAreNotCollapsedToBooleans() {
        let output = AnalyticsSanitizer.properties([
            "pay_via_bank_status": NSNumber(value: 1),
            "enabled": NSNumber(value: true),
        ])

        XCTAssertEqual(output["pay_via_bank_status"] as? Int, 1)
        XCTAssertFalse(output["pay_via_bank_status"] is Bool)
        XCTAssertEqual(output["enabled"] as? Bool, true)
    }

    func testSensitiveSubstringsInsideStringValuesAreRedacted() {
        let output = AnalyticsSanitizer.properties([
            "error_message": "Card 4111 1111 1111 1111 declined for someone@example.com (PAN ABCDE1234F)",
            "failure_reason": "otp sent to 98765 43210",
        ])

        XCTAssertEqual(
            output["error_message"] as? String,
            "Card [REDACTED] declined for [REDACTED] (PAN [REDACTED])"
        )
        XCTAssertEqual(output["failure_reason"] as? String, "otp sent to [REDACTED]")
    }

    func testIdentifierAndJoinFieldsComeThroughVerbatim() {
        let input: [String: Any?] = [
            "order_id": "order_6af743563",
            "subscription_id": "sub_1234567890",
            "public_key": "live_pk_1234567890abcdef",
            "session_id": "01d245ac-f936-4545-9013-7114243e312f",
            "distinct_id": "order_6af743563",
            "$insert_id": "c1a9e4a2-3b51-4d3c-8b2e-123456789012",
            "timestamp": "2026-10-01T10:15:30.123+05:30",
            "sdk_version": "1.0.0",
            "payment_id": "pay_1234567890",
            "checkout_url": "https://checkout.glomopay.com/?orderId=order_123456789&publicKey=live_pk_123456789&mode=live",
        ]

        let output = AnalyticsSanitizer.properties(input.merging(["status_code": 502]) { current, _ in current })

        for (key, value) in input {
            XCTAssertEqual(output[key] as? String, value as? String, key)
        }
        XCTAssertEqual(output["status_code"] as? Int, 502)
    }

    func testDeviceAndHostAppMetadataIsNotRewrittenByRedaction() {
        // Host-app formats the SDK does not control, each of which free-text redaction would
        // otherwise rewrite (a 6+ digit run after "-", "." or "(").
        let input: [String: Any?] = [
            "$app_version_string": "1.4.0-20261001",
            "$app_build_number": "2026.10.01.123456",
            "$app_name": "Wallet (1234567)",
            "$app_namespace": "com.merchant.app",
            "$model": "iPhone15,2",
            "$os_version": "17.4.1",
            "device_os_version": "17.4.1",
            "$lib_version": "1.0.0",
            "payment_id": "pay-1234567890",
        ]

        let output = AnalyticsSanitizer.properties(input)

        for (key, value) in input {
            XCTAssertEqual(output[key] as? String, value as? String, key)
        }
    }

    func testStringValuesAreStillCappedAtOneThousandCharacters() {
        let output = AnalyticsSanitizer.properties([
            "plain": String(repeating: "a", count: 1_500),
            "error_message": "someone@example.com " + String(repeating: "b", count: 1_500),
        ])

        XCTAssertEqual((output["plain"] as? String)?.count, 1_000)
        let redacted = output["error_message"] as? String
        XCTAssertEqual(redacted?.count, 1_000)
        XCTAssertEqual(redacted?.hasPrefix("[REDACTED] bbb"), true)
    }

    func testNullableCompliancePropertiesArePreserved() {
        let output = AnalyticsSanitizer.properties(["is_compliant": nil])

        XCTAssertTrue(output["is_compliant"] is NSNull)
    }
}
