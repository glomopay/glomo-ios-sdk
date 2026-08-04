import XCTest
@testable import GlomoPaySDK

final class ContractCoverageTests: XCTestCase {
    func testValidatorAcceptsSupportedKeyPrefixesAndRejectsUnknownKeys() {
        XCTAssertTrue(Validator.isValidPublicKey("live_123456"))
        XCTAssertTrue(Validator.isValidPublicKey("test_123456"))
        XCTAssertTrue(Validator.isValidPublicKey("mock_123456"))
        XCTAssertFalse(Validator.isValidPublicKey("publishable_123456"))
        XCTAssertFalse(Validator.isValidPublicKey("test_"))
    }

    func testValidatorRejectsMissingMixedAndMalformedIdentifiers() {
        XCTAssertEqual(
            Validator.validateCheckoutIdentifier(orderId: nil, subscriptionId: nil).first?.field,
            "identifier"
        )
        XCTAssertEqual(
            Validator.validateCheckoutIdentifier(orderId: "order_123", subscriptionId: "sub_123").first?.field,
            "identifier"
        )
        XCTAssertEqual(
            Validator.validateCheckoutIdentifier(orderId: "cart_123", subscriptionId: nil).first?.field,
            "orderId"
        )
        XCTAssertEqual(
            Validator.validateCheckoutIdentifier(orderId: nil, subscriptionId: "subscription_123").first?.field,
            "subscriptionId"
        )
    }

    func testConfigValidationCollectsKeyIdentifierAndServerErrors() {
        let config = GlomoPayConfig(
            publicKey: "invalid",
            orderId: "order_123456",
            subscriptionId: "sub_123456",
            server: "http://[invalid"
        )

        let errors = Validator.validate(config: config)

        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors.map(\.field), ["publicKey", "identifier", "server"])
    }

    func testCheckoutURLEncodesIdentifiersAndUsesSubscriptionId() throws {
        let config = GlomoPayConfig(
            publicKey: "test_public_key",
            subscriptionId: "sub_123456"
        )

        let url = try GlomoPaySDK.shared.checkoutURL(for: config)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(query["orderId"], "sub_123456")
        XCTAssertEqual(query["publicKey"], "test_public_key")
        XCTAssertEqual(query["mode"], "mock")
    }

    func testCustomServerGetsTrailingSlashAndLRSUsesItsHost() throws {
        let config = GlomoPayConfig(publicKey: "live_public_key", orderId: "order_123456", server: "https://merchant.example/checkout")

        let standard = try GlomoPaySDK.shared.checkoutURL(for: config)
        let lrs = try GlomoPaySDK.shared.checkoutURL(for: config, orderType: "LRS")

        XCTAssertEqual(standard.host, "merchant.example")
        XCTAssertEqual(standard.path, "/checkout")
        XCTAssertEqual(lrs.host, "merchant.example")
        XCTAssertEqual(ConfigManager.getMode("live_public_key"), "live")
    }

    func testPayloadNormalizesNestedAndSnakeCaseFields() {
        let payload = GlomoPayPayload(json: [
            "type": "payment.success",
            "payload": [
                "order_id": "order_123456",
                "payment_id": "pay_123456",
                "signature": "signed",
            ],
        ])

        XCTAssertEqual(payload.orderId, "order_123456")
        XCTAssertEqual(payload.paymentId, "pay_123456")
        XCTAssertEqual(payload.signature, "signed")
        XCTAssertTrue(Validator.isValidPaymentPayload(payload))
    }

    func testConnectionErrorMapsNetworkSSLAndIOSParseFailure() {
        let offline = ConnectionError.fromWebResourceError(
            description: "offline", errorCode: NSURLErrorNotConnectedToInternet
        )
        let ssl = ConnectionError.fromWebResourceError(
            description: "certificate", errorCode: NSURLErrorServerCertificateUntrusted
        )
        let parseFailure = ConnectionError.fromWebResourceError(
            description: "cannot parse response", errorCode: -1017
        )

        XCTAssertEqual(offline.type, .noInternet)
        XCTAssertTrue(offline.isRecoverable)
        XCTAssertEqual(ssl.type, .sslError)
        XCTAssertFalse(ssl.isRecoverable)
        XCTAssertEqual(parseFailure.type, .webResourceError)
        XCTAssertTrue(parseFailure.shouldAutoClose)
        XCTAssertEqual(parseFailure.errorCode, -1017)
    }

    func testInjectionScriptsAreIdempotentAndDoNotForcePageScrolling() {
        XCTAssertTrue(GlomoPayInjectionScripts.main.contains("GlomoPayBridge"))
        XCTAssertTrue(GlomoPayInjectionScripts.main.contains("__glomoDevMode__"))
        XCTAssertTrue(GlomoPayInjectionScripts.main.contains("__glomo_ GlomoPayBridge_Injected__".replacingOccurrences(of: " ", with: "")))
        XCTAssertFalse(GlomoPayInjectionScripts.main.contains("scrollIntoView"))
        XCTAssertTrue(GlomoPayInjectionScripts.credentialedRequestsFix.contains("credentials"))
        XCTAssertTrue(GlomoPayInjectionScripts.iosInputZoomFix.contains("font-size: 16px"))
        XCTAssertTrue(GlomoPayInjectionScripts.iosInputZoomFix.contains("__glomoIOSInputZoomFixApplied__"))
        XCTAssertTrue(GlomoPayInjectionScripts.iosViewportFitFix.contains("initial-scale=1"))
        XCTAssertTrue(GlomoPayInjectionScripts.iosViewportFitFix.contains("user-scalable=no"))
        XCTAssertTrue(GlomoPayInjectionScripts.flow.contains("GlomoPayFlowBridge"))
        XCTAssertTrue(GlomoPayInjectionScripts.flow.contains("window.open"))
    }

    func testBridgeRoutesAnalyticsForWindowAndPaymentEvents() {
        let listener = ContractCoverageListener()
        var analyticsNames: [String] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            onAnalyticsEvent: { name, _ in analyticsNames.append(name) }
        )

        router.handle(envelope: ["type": "window.open", "url": "https://bank.example"])
        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed",
                ],
            ],
        ])

        XCTAssertEqual(analyticsNames, [
            GlomoPayAnalyticsEvents.windowOpen,
            GlomoPayAnalyticsEvents.paymentSuccess,
        ])
        XCTAssertEqual(listener.successes.count, 1)
    }

    func testBridgeRejectsMalformedEnvelopeAndInvalidWindowURL() {
        let listener = ContractCoverageListener()
        let router = GlomoPayEventRouter(listener: listener, devMode: false, onComplete: { _ in })

        router.handle(envelope: [:])
        router.handle(envelope: ["type": "window.open", "url": "http://[invalid"])

        XCTAssertEqual(listener.errors.count, 2)
        XCTAssertTrue(listener.errors.allSatisfy { $0.type == .unknown })
    }

    func testDuplicatePaymentDoesNotDuplicateAnalytics() {
        let listener = ContractCoverageListener()
        var analyticsNames: [String] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            onAnalyticsEvent: { name, _ in analyticsNames.append(name) }
        )
        let event: [String: Any] = [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed",
                ],
            ],
        ]

        router.handle(envelope: event)
        router.handle(envelope: event)

        XCTAssertEqual(listener.successes.count, 1)
        XCTAssertEqual(analyticsNames, [GlomoPayAnalyticsEvents.paymentSuccess])
    }
}

private final class ContractCoverageListener: GlomoPayListener {
    var successes: [GlomoPayPayload] = []
    var errors: [SdkError] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) {}
    func onSdkError(_ errors: [SdkError]) { self.errors.append(contentsOf: errors) }
    func onConnectionError(_ error: ConnectionError) {}
}
