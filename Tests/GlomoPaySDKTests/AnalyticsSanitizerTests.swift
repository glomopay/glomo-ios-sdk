import XCTest
@testable import GlomoPaySDK

final class AnalyticsSanitizerTests: XCTestCase {
    func testBankRedirectKeepsOnlyHTTPSOrigin() {
        let url = URL(string: "https://user:pass@3DS.IN.Secure.Bank.COM:8443/verify/ABCDE1234F?phone=9876543210#otp")!

        XCTAssertEqual(AnalyticsSanitizer.bankRedirectURL(url), "https://3ds.in.secure.bank.com")
        XCTAssertNil(AnalyticsSanitizer.bankRedirectURL(URL(string: "http://bank.example/otp")))
    }

    func testPIIIsRedactedWhileOpaqueGlomoIdentifiersRemain() {
        let output = AnalyticsSanitizer.properties([
            "order_id": "order_6af743563",
            "message": "user@example.com 9876543210 ABCDE1234F N1234567 ABC1234567",
            "customer_email": "user@example.com",
        ])

        XCTAssertEqual(output["order_id"] as? String, "order_6af743563")
        XCTAssertEqual(output["message"] as? String, "[REDACTED] [REDACTED] [REDACTED] [REDACTED] [REDACTED]")
        XCTAssertNil(output["customer_email"])
    }

    func testTimestampIsNotRedactedAsNumericPII() {
        let timestamp = "2026-08-17T14:33:19.153+05:30"
        let output = AnalyticsSanitizer.properties(["timestamp": timestamp])

        XCTAssertEqual(output["timestamp"] as? String, timestamp)
    }

    func testNullableCompliancePropertiesArePreserved() {
        let output = AnalyticsSanitizer.properties(["is_compliant": nil])

        XCTAssertTrue(output["is_compliant"] is NSNull)
    }
}
