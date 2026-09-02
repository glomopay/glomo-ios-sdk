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
            "$insert_id": uuid,
            "distinct_id": uuid,
        ])

        XCTAssertEqual(output["session_id"] as? String, uuid)
        XCTAssertEqual(output["$insert_id"] as? String, uuid)
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

    func testNullableCompliancePropertiesArePreserved() {
        let output = AnalyticsSanitizer.properties(["is_compliant": nil])

        XCTAssertTrue(output["is_compliant"] is NSNull)
    }
}
