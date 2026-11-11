import XCTest

@testable import GlomoPaySDK

/// Finding 3 of the Oct 2026 source review: the privileged bridges were reachable from any
/// document the WebViews loaded, which on the flow WebView means every bank and 3-D Secure page.
final class BridgeOriginGateTests: XCTestCase {
    private let trusted: Set<String> = ["https://checkout.glomopay.com"]
    private let glomoFrame = BridgeMessageSender(origin: "https://checkout.glomopay.com", isMainFrame: true)
    private let bankFrame = BridgeMessageSender(origin: "https://netbanking.bank.example", isMainFrame: true)

    private let paymentSuccess = """
    {"type":"message","data":{"type":"payment.success","payload":\
    {"orderId":"order_1","paymentId":"pay_1","signature":"sig_1"}}}
    """

    private func makeRouter(
        listener: MockGateListener,
        reporter: GateReporter = GateReporter(),
        onWindowClose: @escaping () -> Void = {},
        onWindowOpen: @escaping (URL) -> Void = { _ in },
        result: @escaping (GlomoPayResult) -> Void = { _ in }
    ) -> GlomoPayEventRouter {
        GlomoPayEventRouter(
            listener: listener,
            onComplete: result,
            onWindowOpen: onWindowOpen,
            onWindowClose: onWindowClose,
            analytics: GateAnalytics(),
            errorReporter: reporter,
            trustedOrigins: trusted
        )
    }

    func testPaymentEventFromABankPageIsDropped() {
        let listener = MockGateListener()
        var result: GlomoPayResult?
        let router = makeRouter(listener: listener, result: { result = $0 })

        router.handle(body: paymentSuccess, sender: bankFrame)

        XCTAssertTrue(listener.successes.isEmpty)
        XCTAssertNil(result)
    }

    func testPaymentEventFromAGlomoPayPageIsDelivered() {
        let listener = MockGateListener()
        var result: GlomoPayResult?
        let router = makeRouter(listener: listener, result: { result = $0 })

        router.handle(body: paymentSuccess, sender: glomoFrame)

        XCTAssertEqual(listener.successes.first?.orderId, "order_1")
        XCTAssertNotNil(result)
    }

    /// `forMainFrameOnly` is false on every user script, so an iframe on one of our own pages can
    /// reach the channel. WebKit reports the sending frame, which is why this is checkable at all.
    func testPaymentEventFromASubframeOfOurOwnPageIsDropped() {
        let listener = MockGateListener()
        let router = makeRouter(listener: listener)

        router.handle(
            body: paymentSuccess,
            sender: BridgeMessageSender(origin: "https://checkout.glomopay.com", isMainFrame: false)
        )

        XCTAssertTrue(listener.successes.isEmpty)
    }

    func testAMessageWithNoAttributableOriginIsDropped() {
        let listener = MockGateListener()
        let router = makeRouter(listener: listener)

        router.handle(body: paymentSuccess, sender: BridgeMessageSender(origin: nil, isMainFrame: true))

        XCTAssertTrue(listener.successes.isEmpty)
    }

    /// The flow injection replaces `window.open` and `window.close` on the bank's own document, so
    /// a bank calling them is how the overlay navigates and dismisses. Gating those would strand
    /// the user on a finished 3-D Secure page.
    func testBankDrivenNavigationStillWorksFromABankPage() {
        let listener = MockGateListener()
        var closed = 0
        var opened: URL?
        let router = makeRouter(
            listener: listener,
            onWindowClose: { closed += 1 },
            onWindowOpen: { opened = $0 }
        )

        router.handle(body: #"{"type":"window.open","url":"https://bank.example/step2"}"#, sender: bankFrame)
        router.handle(body: #"{"type":"window.close"}"#, sender: bankFrame)

        XCTAssertEqual(opened?.absoluteString, "https://bank.example/step2")
        XCTAssertEqual(closed, 1)
    }

    func testABankPageCannotPutTheCheckoutOnTheErrorScreen() {
        let listener = MockGateListener()
        let reporter = GateReporter()
        let router = makeRouter(listener: listener, reporter: reporter)

        router.handle(body: #"{"type":"dependencies.failed_to_load"}"#, sender: bankFrame)

        XCTAssertTrue(reporter.operations.contains("bridge_message_untrusted_origin"))
    }
}

final class TrustedOriginTests: XCTestCase {
    func testDropsTheSchemeDefaultPortSoBothSpellingsMatch() {
        XCTAssertEqual(
            TrustedOrigin.origin(of: URL(string: "https://checkout.example.com:443/pay")),
            TrustedOrigin.origin(of: URL(string: "https://checkout.example.com/pay"))
        )
    }

    func testKeepsANonDefaultPort() {
        XCTAssertEqual(
            TrustedOrigin.origin(of: URL(string: "https://checkout.example.com:8443/")),
            "https://checkout.example.com:8443"
        )
    }

    func testReadsTheHostAndNotTheUserinfo() {
        XCTAssertEqual(
            TrustedOrigin.origin(of: URL(string: "https://checkout.example.com@attacker.test/pay")),
            "https://attacker.test"
        )
    }

    func testRejectsAnythingThatIsNotHTTP() {
        XCTAssertNil(TrustedOrigin.origin(of: URL(string: "upi://pay?pa=someone")))
        XCTAssertNil(TrustedOrigin.origin(of: URL(string: "about:blank")))
        XCTAssertNil(TrustedOrigin.origin(of: nil))
    }

    func testPageOriginsCoverEveryPageTheSDKServesAndExcludeABank() {
        let config = GlomoPayConfig(publicKey: "live_abc", orderId: "order_1")
        let origins = TrustedOrigin.pageOrigins(for: config)

        XCTAssertTrue(origins.contains(TrustedOrigin.origin(of: URL(string: ConfigManager.defaultStandardBaseURL))!))
        XCTAssertTrue(origins.contains(TrustedOrigin.origin(of: URL(string: ConfigManager.defaultLRSBaseURL))!))
        XCTAssertTrue(origins.contains(TrustedOrigin.origin(of: URL(string: ConfigManager.carouselBaseURL))!))
        XCTAssertFalse(origins.contains("https://netbanking.bank.example"))
    }

    /// A merchant on a custom server has to be covered by the same list, or the gate drops their
    /// own checkout page.
    func testACustomServerIsTrusted() {
        let config = GlomoPayConfig(publicKey: "live_abc", orderId: "order_1", server: "https://pay.merchant.example")
        XCTAssertTrue(TrustedOrigin.pageOrigins(for: config).contains("https://pay.merchant.example"))
    }

    func testAGlomoDomainTheConfigNeverNamedIsTrusted() {
        // The whole point: an installed SDK cannot be updated the day checkout moves domain.
        let config = GlomoPayConfig(publicKey: "live_abc", orderId: "order_1")
        let origins = TrustedOrigin.pageOrigins(for: config)

        XCTAssertTrue(TrustedOrigin.isTrusted("https://checkout.glomo.one", in: origins))
        XCTAssertTrue(TrustedOrigin.isTrusted("https://lrs-checkout.glomo.one", in: origins))
        XCTAssertFalse(origins.contains("https://checkout.glomo.one"))
    }

    func testTheSuffixRuleDoesNotAdmitALookalike() {
        let origins: Set<String> = []
        XCTAssertFalse(TrustedOrigin.isTrusted("https://glomo.one.attacker.test", in: origins))
        XCTAssertFalse(TrustedOrigin.isTrusted("https://attackerglomo.one", in: origins))
        XCTAssertFalse(TrustedOrigin.isTrusted("https://notglomopay.com", in: origins))
    }

    func testTheSuffixRuleIsHTTPSOnDefaultPortOnly() {
        let origins: Set<String> = []
        XCTAssertFalse(TrustedOrigin.isTrusted("http://checkout.glomo.one", in: origins))
        XCTAssertFalse(TrustedOrigin.isTrusted("https://checkout.glomo.one:8443", in: origins))
    }

    func testConfiguredOriginsOffAGlomoDomainAreStillTrusted() {
        let config = GlomoPayConfig(publicKey: "live_abc", orderId: "order_1")
        let origins = TrustedOrigin.pageOrigins(for: config)
        let carousel = TrustedOrigin.origin(of: URL(string: ConfigManager.carouselBaseURL))

        // Firebase Hosting, not a Glomo domain - covered only by the configured set.
        XCTAssertFalse(TrustedOrigin.isGlomoHost("glomopay-utilities.web.app"))
        XCTAssertTrue(TrustedOrigin.isTrusted(carousel, in: origins))
    }

    func testAHostThatMerelyEndsWithATrustedOneIsNotTrusted() {
        let config = GlomoPayConfig(publicKey: "live_abc", orderId: "order_1")
        let origins = TrustedOrigin.pageOrigins(for: config)

        XCTAssertFalse(origins.contains("https://checkout.glomopay.com.attacker.test"))
        // A subdomain of ours is ours - reachable only by whoever controls our DNS - so the
        // suffix rule trusts it even though the configured set does not name it.
        XCTAssertFalse(origins.contains("https://attacker-checkout.glomopay.com"))
        XCTAssertTrue(TrustedOrigin.isTrusted("https://attacker-checkout.glomopay.com", in: origins))
    }
}

private final class MockGateListener: GlomoPayListener {
    var successes: [GlomoPayPayload] = []
    var errors: [SdkError] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) {}
    func onSdkError(_ errors: [SdkError]) { self.errors.append(contentsOf: errors) }
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) {}
    func onConnectionError(_ error: ConnectionError) {}
    func onPaymentTerminate(_ source: TerminationSource) {}
}

private final class GateReporter: SDKErrorReporting, @unchecked Sendable {
    var operations: [String] = []
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) { operations.append(operation) }
}

private final class GateAnalytics: AnalyticsTracking {
    func track(_ event: String, properties: [String: Any?]) {}
    func updateFlowType(_ flowType: String) {}
}
