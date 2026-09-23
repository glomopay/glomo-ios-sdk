import XCTest
@testable import GlomoPaySDK

final class ContractCoverageTests: XCTestCase {
    func testWebContentProcessRecoveryRetriesMainOnceAndClosesFlow() {
        XCTAssertEqual(
            WebContentProcessRecovery.action(isFlow: true, didRetryMain: false, hasCurrentURL: true),
            .closeFlow
        )
        XCTAssertEqual(
            WebContentProcessRecovery.action(isFlow: false, didRetryMain: false, hasCurrentURL: true),
            .reloadMain
        )
        XCTAssertEqual(
            WebContentProcessRecovery.action(isFlow: false, didRetryMain: true, hasCurrentURL: true),
            .reportMainFailure
        )
        XCTAssertEqual(
            WebContentProcessRecovery.action(isFlow: false, didRetryMain: false, hasCurrentURL: false),
            .reportMainFailure
        )
    }

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
        XCTAssertEqual(parseFailure.errorCode, -1017)
        // An unmapped failure shows the retry surface; it does not close the checkout. The old
        // rule was `type != .webResourceError || errorCode < 0`, and every NSURLError code is
        // negative, so every unmapped error auto-closed.
        XCTAssertFalse(parseFailure.shouldAutoClose)
        XCTAssertTrue(offline.shouldAutoClose)
        XCTAssertTrue(ssl.shouldAutoClose)
    }

    func testAutoCloseIsDecidedByMappedTypeNotTheSignOfTheErrorCode() {
        // WKErrorDomain codes are positive, so the old sign test exempted genuine WebKit
        // failures from auto-close while closing on every NSURLError.
        let webKitFailure = ConnectionError.fromWebResourceError(
            description: "web content process terminated",
            errorCode: 3,
            domain: "WKErrorDomain"
        )
        XCTAssertEqual(webKitFailure.type, .webResourceError)
        XCTAssertFalse(webKitFailure.shouldAutoClose)

        // A timeout does not self-close: the network may become available again.
        let timeout = ConnectionError.fromWebResourceError(
            description: "timed out", errorCode: NSURLErrorTimedOut
        )
        XCTAssertEqual(timeout.type, .timeout)
        XCTAssertFalse(timeout.shouldAutoClose)
    }

    func testCancelledNavigationsAreNotTreatedAsConnectionFailures() {
        // WebKit delivers NSURLErrorCancelled routinely: superseded provisional navigations,
        // client-side redirects during load, and stopLoading().
        XCTAssertTrue(ConnectionError.isCancellation(domain: NSURLErrorDomain, errorCode: NSURLErrorCancelled))
        XCTAssertFalse(ConnectionError.isCancellation(domain: "WKErrorDomain", errorCode: NSURLErrorCancelled))
        XCTAssertFalse(ConnectionError.isCancellation(domain: NSURLErrorDomain, errorCode: NSURLErrorTimedOut))
    }

    func testFlowWebViewBlocksEverythingOutsideTheWebAllowlist() {
        for allowed in [
            "https://bank.example/3ds",
            "http://bank.example",
            "about:blank",
            "blob:https://bank.example/id",
            "data:text/html,<h1>x</h1>",
        ] {
            XCTAssertTrue(FlowNavigationPolicy.allows(URL(string: allowed)), allowed)
        }
        for blocked in ["upi://pay", "intent://bank", "javascript:alert(1)", "file:///etc/passwd", "tel:123"] {
            XCTAssertFalse(FlowNavigationPolicy.allows(URL(string: blocked)), blocked)
        }
        XCTAssertFalse(FlowNavigationPolicy.allows(nil))
        XCTAssertEqual(FlowNavigationPolicy.scheme(of: URL(string: "UPI://pay")), "upi")
        XCTAssertEqual(FlowNavigationPolicy.scheme(of: nil), "none")
    }

    func testValidatorRejectsEveryURLShapeThatIsNotAWebNavigation() {
        for valid in ["https://bank.example", "http://bank.example/3ds?a=1", "HTTPS://Bank.Example"] {
            XCTAssertTrue(Validator.isValidUrl(valid), valid)
        }
        for invalid in [
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>",
            "file:///etc/passwd",
            "about:blank",
            "upi://pay",
            "https://",
            "https://user:pass@bank.example",
            "//bank.example",
            "bank.example",
            "",
        ] {
            XCTAssertFalse(Validator.isValidUrl(invalid), invalid)
        }
    }

    func testEducationCarouselContractMatchesTheHostedPageMessage() {
        // Built from the page's message shape, not from the field names in any SDK.
        let message = #"{"event":"lrs.has_education_steps","hasContent":true}"#
        XCTAssertEqual(EducationCarouselContract.parseAvailabilitySignal(rawMessage: message), true)
        XCTAssertEqual(
            EducationCarouselContract.parseAvailabilitySignal(
                rawMessage: #"{"event":"lrs.has_education_steps","hasContent":false}"#
            ),
            false
        )
        // The shape Android was reading is not what the page sends.
        XCTAssertNil(
            EducationCarouselContract.parseAvailabilitySignal(
                rawMessage: #"{"type":"lrs.has_education_steps","value":true}"#
            )
        )
        XCTAssertNil(EducationCarouselContract.parseAvailabilitySignal(rawMessage: "not-json"))
        XCTAssertNil(EducationCarouselContract.availabilitySignal(["event": "other", "hasContent": true]))
    }

    func testEducationCarouselLayoutMatchesFlutterProportions() {
        let showing = EducationCarouselContract.layout(
            state: .hasContent, isLRSOrder: true, isSubscription: false
        )
        XCTAssertTrue(showing.showsCarousel)
        XCTAssertEqual(showing.barFraction, 0.05)
        XCTAssertEqual(showing.carouselFraction, 0.15)
        XCTAssertNil(showing.barHeight)

        // A fixed bar when hidden: a percentage would give a different height per screen size.
        for hidden in [
            EducationCarouselContract.layout(state: .pending, isLRSOrder: true, isSubscription: false),
            EducationCarouselContract.layout(state: .noContent, isLRSOrder: true, isSubscription: false),
            EducationCarouselContract.layout(state: .hasContent, isLRSOrder: false, isSubscription: false),
            EducationCarouselContract.layout(state: .hasContent, isLRSOrder: true, isSubscription: true),
        ] {
            XCTAssertFalse(hidden.showsCarousel)
            XCTAssertEqual(hidden.barHeight, 48)
            XCTAssertEqual(hidden.carouselFraction, 0)
        }
    }

    func testFlowInjectionCarriesTheOpenerStubBeforeBankScriptsRun() {
        // Bank pages opened through window.open call opener.postMessage() during load; without
        // the stub the payment completes at the bank and the SDK never hears about it.
        XCTAssertTrue(GlomoPayInjectionScripts.flow.contains("window.opener"))
        XCTAssertTrue(GlomoPayInjectionScripts.flow.contains("__glomoOpenerStubInjected__"))
        XCTAssertTrue(GlomoPayInjectionScripts.flow.contains("GlomoPayFlowBridge"))
        XCTAssertTrue(GlomoPayInjectionScripts.flow.contains("__glomoBridge__"))
        XCTAssertFalse(GlomoPayInjectionScripts.main.contains("window.opener ="))
        XCTAssertTrue(GlomoPayInjectionScripts.main.contains("bridge.ready"))
        XCTAssertFalse(GlomoPayInjectionScripts.flow.contains("bridge.ready"))

        XCTAssertTrue(GlomoPayInjectionScripts.carousel().contains("lrs.has_education_steps"))
        XCTAssertTrue(GlomoPayInjectionScripts.carousel().contains("hasContent"))
        XCTAssertTrue(GlomoPayInjectionScripts.carouselFallback().contains("3000"))
        XCTAssertTrue(GlomoPayInjectionScripts.carouselFallback().contains("__glomoCarouselStateSent__"))
    }

    func testCarouselURLCarriesProductAndSurface() throws {
        let config = GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123456")
        let url = try XCTUnwrap(ConfigManager.getCarouselURL(config))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(values["orderId"], "order_123456")
        XCTAssertEqual(values["publicKey"], "test_public_key")
        XCTAssertEqual(values["product"], "checkout-ios-sdk")
        XCTAssertEqual(values["surface"], "ios")
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

    func testBridgeRoutesWindowAndPaymentEvents() {
        let listener = ContractCoverageListener()
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
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

        XCTAssertEqual(listener.successes.count, 1)
    }

    func testBridgeRejectsMalformedEnvelopeAndInvalidWindowURL() {
        let listener = ContractCoverageListener()
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [:])
        router.handle(envelope: ["type": "window.open", "url": "http://[invalid"])

        XCTAssertEqual(listener.errors.count, 2)
        XCTAssertTrue(listener.errors.allSatisfy { $0.type == .unknown })
    }

    func testDuplicatePaymentDoesNotDuplicateCompletion() {
        let listener = ContractCoverageListener()
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
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
    }
}

extension ContractCoverageTests {
    /// A failure payload has never carried a signature - that field exists so a host can verify a
    /// success - so requiring one meant onPaymentFailure could not fire for a confirmed decline,
    /// and the host got an onSdkError describing the SDK's own guard instead.
    func testFailureIsDeliveredOnTheEventNameWithoutASignature() {
        for eventName in ["payment.failure", "payment.failed", "failed", "payment.error"] {
            let listener = FailureRecordingListener()
            var results: [GlomoPayResult] = []
            let router = GlomoPayEventRouter(
                listener: listener,
                devMode: false,
                onComplete: { results.append($0) },
                analytics: NoOpAnalyticsTracker(),
                errorReporter: NoOpSDKErrorReporter()
            )

            router.handle(envelope: [
                "type": "message",
                "data": [
                    "type": eventName,
                    "payload": ["orderId": "order_123456", "reason": "issuer_declined"],
                ],
            ])

            XCTAssertEqual(listener.failures.count, 1, eventName)
            XCTAssertNil(listener.failures.first?.signature, eventName)
            XCTAssertEqual(listener.failures.first?.orderId, "order_123456", eventName)
            XCTAssertEqual(results.count, 1, eventName)
            // Not an SDK error: the bank declined the payment, the SDK did not fail.
            XCTAssertTrue(listener.errors.isEmpty, eventName)
        }
    }

    func testThinFailurePayloadIsStillDeliveredAndCaptured() {
        let listener = FailureRecordingListener()
        let reporter = OperationRecordingReporter()
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: reporter
        )

        router.handle(envelope: ["type": "message", "data": ["type": "payment.failure"]])

        XCTAssertEqual(listener.failures.count, 1)
        XCTAssertEqual(reporter.operations, ["thin_payment_failure_payload"])
    }

    func testBankTransferIsAJourneyAndNeverAPaymentSuccess() {
        let listener = FailureRecordingListener()
        var results: [GlomoPayResult] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { results.append($0) },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.bank_transfer_submitted",
                "payload": [
                    "orderId": "order_123456",
                    "sender_account_number": "000123456789",
                    "transactionReference": "utr_1",
                    "status": "submitted",
                ],
            ],
        ])

        // No money has moved: reporting this as a payment success handed the host a payload with
        // no paymentId and no signature to verify against.
        XCTAssertTrue(listener.successes.isEmpty)
        XCTAssertEqual(listener.journeys.count, 1)
        let journey = listener.journeys.first
        XCTAssertEqual(journey?.journeyType, .bankTransferSubmitted)
        XCTAssertEqual(journey?.journeyType.rawValue, "bank_transfer_submitted")
        XCTAssertEqual(journey?.orderId, "order_123456")
        // Both casings are read, because the page has sent both.
        XCTAssertEqual(journey?.senderAccountNumber, "000123456789")
        XCTAssertEqual(journey?.transactionReference, "utr_1")
        XCTAssertEqual(journey?.status, "submitted")
        XCTAssertEqual(results.count, 1)
    }

    func testJourneyFieldsSurviveNonStringValuesAndSnakeCase() {
        let payload = GlomoPayUserJourneyPayload(
            journeyType: .bankTransferSubmitted,
            json: [
                "order_id": "order_2",
                "senderAccountNumber": 123456789,
                "transaction_reference": 42,
            ]
        )

        // A cast would throw inside the delivery path after the one-result latch is spent.
        XCTAssertEqual(payload.orderId, "order_2")
        XCTAssertEqual(payload.senderAccountNumber, "123456789")
        XCTAssertEqual(payload.transactionReference, "42")
        XCTAssertNil(payload.status)
    }

    func testThinBankTransferPayloadIsRejectedButLeavesATrace() {
        let listener = FailureRecordingListener()
        let reporter = OperationRecordingReporter()
        var results: [GlomoPayResult] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { results.append($0) },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: reporter
        )

        router.handle(envelope: [
            "type": "message",
            "data": ["type": "payment.bank_transfer_submitted", "payload": ["status": "submitted"]],
        ])

        XCTAssertTrue(listener.journeys.isEmpty)
        XCTAssertTrue(listener.successes.isEmpty)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(reporter.operations, ["thin_bank_transfer_payload"])
        // Not a generic SDK error about the SDK's own guard.
        XCTAssertTrue(listener.errors.isEmpty)
    }

    func testJourneyTypeCarriesOnlyTheSupportedFlow() {
        // Pay-via-bank is sunset on iOS: a member a host can receive but never see is a question
        // every integration has to ask us about once.
        XCTAssertEqual(GlomoPayUserJourneyType.allCases.map(\.rawValue), ["bank_transfer_submitted"])
    }

    func testPayViaBankTerminalEventIsNoLongerTrackedAsASupportedFlow() {
        let analytics = OperationRecordingAnalytics()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "message",
            "data": ["type": "glomoCheckoutJourneyTerminate", "status": "completed"],
        ])

        // It used to emit Pay Via Bank Completed, which made a dashboard show a live-looking
        // signal for a journey no merchant is told about.
        XCTAssertFalse(analytics.names.contains("Pay Via Bank Completed"))
        XCTAssertEqual(analytics.names, [AnalyticsEventName.unsupportedFunctionalityUsed])
    }

    func testDependencyFailureIsTrackedOnceUnderThePagesOwnName() {
        let analytics = OperationRecordingAnalytics()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: ["type": "dependencies.failed_to_load", "message": "LRS data missing"])
        // The same failure arriving through the page-message channel must not be counted twice.
        router.handle(envelope: ["type": "message", "data": ["type": "dependencies.failed_to_load"]])

        XCTAssertEqual(
            analytics.names.filter { $0 == AnalyticsEventName.checkoutDependenciesFailed }.count,
            1
        )
    }
}

private final class FailureRecordingListener: GlomoPayListener {
    var successes: [GlomoPayPayload] = []
    var failures: [GlomoPayPayload] = []
    var journeys: [GlomoPayUserJourneyPayload] = []
    var errors: [SdkError] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) { failures.append(payload) }
    func onSdkError(_ errors: [SdkError]) { self.errors.append(contentsOf: errors) }
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) { journeys.append(payload) }
    func onConnectionError(_ error: ConnectionError) {}
}

private final class OperationRecordingReporter: SDKErrorReporting, @unchecked Sendable {
    var operations: [String] = []
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) { operations.append(operation) }
}

private final class OperationRecordingAnalytics: AnalyticsTracking {
    var names: [String] = []
    func track(_ event: String, properties: [String: Any?]) { names.append(event) }
    func updateFlowType(_ flowType: String) {}
    func updateCheckoutURL(_ url: URL) {}
}

private final class ContractCoverageListener: GlomoPayListener {
    var journeys: [GlomoPayUserJourneyPayload] = []
    var successes: [GlomoPayPayload] = []
    var errors: [SdkError] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) {}
    func onSdkError(_ errors: [SdkError]) { self.errors.append(contentsOf: errors) }
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) { journeys.append(payload) }
    func onConnectionError(_ error: ConnectionError) {}
}
