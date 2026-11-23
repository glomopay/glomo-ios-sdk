import XCTest

@testable import GlomoPaySDK

/// A payment stage change as `events-table.md` describes it, with every optional field populated.
private func stageChanged(_ overrides: [String: Any?] = [:]) -> [String: Any] {
    var payload: [String: Any] = [
        "v": 1,
        "method": "lrs",
        "resource": ["type": "order", "id": "order_abc123"],
        "paymentId": "pay_abc123",
        "journeyId": "jrn_abc123",
        "at": "2026-11-23T06:00:00.000Z",
        "flow": "payment",
        "stage": "customer_auth",
        "step": "otp",
        "provider": "HDFC",
        "journeyType": "native",
    ]
    for (key, value) in overrides {
        if let value { payload[key] = value } else { payload.removeValue(forKey: key) }
    }
    return payload
}

private func stageEnvelope(_ payload: [String: Any]?) -> [String: Any] {
    var data: [String: Any] = ["type": "checkout.stage_changed"]
    if let payload { data["payload"] = payload }
    return ["type": "message", "data": data]
}

private func closedEnvelope(_ payload: [String: Any]?) -> [String: Any] {
    var data: [String: Any] = ["type": "checkout.closed"]
    if let payload { data["payload"] = payload }
    return ["type": "message", "data": data]
}

final class CheckoutStageEventsTests: XCTestCase {
    private let trusted: Set<String> = ["https://checkout.glomopay.com"]
    private let glomoFrame = BridgeMessageSender(origin: "https://checkout.glomopay.com", isMainFrame: true)

    private func makeRouter(listener: StageRecordingListener) -> GlomoPayEventRouter {
        GlomoPayEventRouter(
            listener: listener,
            onComplete: { _ in },
            analytics: StageAnalytics(),
            errorReporter: StageReporter(),
            trustedOrigins: trusted
        )
    }

    func testStageChangeReachesTheMerchantWithEveryFieldThePageSent() {
        let listener = StageRecordingListener()
        makeRouter(listener: listener).handle(body: stageEnvelope(stageChanged()), sender: glomoFrame)

        let event = try! XCTUnwrap(listener.stages.first)
        XCTAssertEqual(listener.stages.count, 1)
        XCTAssertEqual(event.version, 1)
        XCTAssertEqual(event.stage, "customer_auth")
        XCTAssertEqual(event.step, "otp")
        XCTAssertEqual(event.provider, "HDFC")
        XCTAssertEqual(event.journeyType, "native")
        XCTAssertEqual(event.method, "lrs")
        XCTAssertEqual(event.paymentId, "pay_abc123")
        XCTAssertEqual(event.journeyId, "jrn_abc123")
        XCTAssertEqual(event.resource, GlomoCheckoutResource(type: "order", id: "order_abc123"))
    }

    func testAnUnrecognisedStageStillReachesTheMerchant() {
        let listener = StageRecordingListener()
        makeRouter(listener: listener)
            .handle(body: stageEnvelope(stageChanged(["stage": "teleported"])), sender: glomoFrame)

        XCTAssertEqual(listener.stages.map(\.stage), ["teleported"])
    }

    func testAStageChangeWithNoPayloadIsIgnoredRatherThanDeliveredEmpty() {
        let listener = StageRecordingListener()
        makeRouter(listener: listener).handle(body: stageEnvelope(nil), sender: glomoFrame)

        XCTAssertTrue(listener.stages.isEmpty)
    }

    func testEveryStageReachesTheMerchantInTheOrderThePageSentThem() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)

        router.handle(body: stageEnvelope(stageChanged(["stage": "opened", "step": "consent"])), sender: glomoFrame)
        router.handle(body: stageEnvelope(stageChanged(["stage": "method_selected", "step": nil])), sender: glomoFrame)
        router.handle(body: stageEnvelope(stageChanged(["stage": "customer_auth", "step": "otp"])), sender: glomoFrame)

        XCTAssertEqual(listener.stages.map(\.stage), ["opened", "method_selected", "customer_auth"])
    }

    func testAPageSentCloseDeliversItsPayloadAndStillTerminatesAsBefore() {
        let listener = StageRecordingListener()
        let closed: [String: Any] = [
            "v": 1,
            "resource": ["type": "order", "id": "order_abc123"],
            "journeyId": "jrn_abc123",
            "at": "2026-11-23T06:05:00.000Z",
            "flow": "payment",
            "lastStage": "customer_auth",
            "lastStep": "otp",
            "reason": "user_cancelled",
        ]

        makeRouter(listener: listener).handle(body: closedEnvelope(closed), sender: glomoFrame)

        let event = try! XCTUnwrap(listener.closes.first)
        XCTAssertEqual(event.reason, "user_cancelled")
        XCTAssertEqual(event.lastStage, "customer_auth")
        XCTAssertEqual(event.lastStep, "otp")
        XCTAssertEqual(listener.terminations, [.userDismiss])
    }

    /// The switch-off path. With checkout progress events off for the merchant the page still
    /// posts the close, with nothing in it, so the pre-v1 behaviour has to survive unchanged.
    func testACloseWithNoPayloadTerminatesExactlyAsItDidBefore() {
        let listener = StageRecordingListener()
        makeRouter(listener: listener).handle(body: closedEnvelope(nil), sender: glomoFrame)

        XCTAssertTrue(listener.closes.isEmpty)
        XCTAssertEqual(listener.terminations, [.userDismiss])
    }

    func testTheLegacyCancelNamesDoNotFabricateACloseEvent() {
        for eventName in ["payment.cancelled", "cancelled"] {
            let listener = StageRecordingListener()
            let envelope: [String: Any] = [
                "type": "message",
                "data": ["type": eventName, "payload": ["foo": "bar"]],
            ]

            makeRouter(listener: listener).handle(body: envelope, sender: glomoFrame)

            XCTAssertTrue(listener.closes.isEmpty, "\(eventName) must not produce a v1 close")
            XCTAssertEqual(listener.terminations, [.userDismiss])
        }
    }

    func testANativeDismissalWritesTheCloseQuotingTheLastStage() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged()), sender: glomoFrame)

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        let event = try! XCTUnwrap(listener.closes.first)
        XCTAssertEqual(event.reason, "user_dismissed")
        XCTAssertEqual(event.lastStage, "customer_auth")
        XCTAssertEqual(event.lastStep, "otp")
        XCTAssertEqual(event.journeyId, "jrn_abc123")
        XCTAssertEqual(event.resource.id, "order_abc123")
        XCTAssertFalse(event.at.isEmpty)
        XCTAssertNotEqual(event.at, "2026-11-23T06:00:00.000Z", "the close is timestamped, not the stage")
    }

    func testANativeDismissalStaysSilentWhenNoStageEverArrived() {
        let listener = StageRecordingListener()
        makeRouter(listener: listener).deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertTrue(listener.closes.isEmpty)
    }

    func testANativeDismissalStaysSilentWhenTheOnlyStageWasUnrecognised() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged(["stage": "teleported"])), sender: glomoFrame)

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertEqual(listener.stages.count, 1)
        XCTAssertTrue(listener.closes.isEmpty)
    }

    /// The dismissal path is reachable more than once - `terminate` and a presentation dismiss can
    /// both run - and neither sets the router's terminal flag, so the one-close rule here rests on
    /// its own latch rather than on the terminal guard above it.
    func testTheCloseIsWrittenOnceHoweverManyTimesTheDismissalPathFires() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged()), sender: glomoFrame)

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)
        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertEqual(listener.closes.count, 1)
    }

    func testANativeDismissalAddsNothingAfterThePageAlreadyClosed() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged()), sender: glomoFrame)
        router.handle(
            body: closedEnvelope([
                "v": 1,
                "resource": ["type": "order", "id": "order_abc123"],
                "journeyId": "jrn_abc123",
                "at": "2026-11-23T06:05:00.000Z",
                "flow": "payment",
                "reason": "user_cancelled",
            ]),
            sender: glomoFrame
        )

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertEqual(listener.closes.map(\.reason), ["user_cancelled"])
    }

    func testANativeDismissalAddsNothingAfterAPaymentOutcomeWasDelivered() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged()), sender: glomoFrame)
        router.handle(
            body: [
                "type": "message",
                "data": [
                    "type": "payment.success",
                    "payload": ["orderId": "order_abc123", "paymentId": "pay_1", "signature": "sig"],
                ],
            ],
            sender: glomoFrame
        )

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertEqual(listener.successes.count, 1)
        XCTAssertTrue(listener.closes.isEmpty)
    }

    /// A checkout closed by host code has no honest reason in the contract - `merchant_closed`
    /// was dropped before it shipped - so nothing is sent.
    func testACloseWithNoContractReasonSaysNothing() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged()), sender: glomoFrame)

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.forTermination(.programmatic))

        XCTAssertTrue(listener.closes.isEmpty)
    }

    func testEachTerminationSourceMapsToTheOnlyHonestContractReason() {
        XCTAssertEqual(GlomoCheckoutCloseReasons.forTermination(.userDismiss), "user_dismissed")
        XCTAssertEqual(GlomoCheckoutCloseReasons.forTermination(.connectionError), "error")
        XCTAssertNil(GlomoCheckoutCloseReasons.forTermination(.programmatic))
    }

    func testARecognisedKycStageIsRememberedEvenThoughLrsNeverSendsOne() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(
            body: stageEnvelope(stageChanged(["flow": "kyc", "stage": "under_review", "step": nil])),
            sender: glomoFrame
        )

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertEqual(listener.closes.map(\.lastStage), ["under_review"])
    }

    func testAKycOnlyStageOnThePaymentFlowIsForwardedButNotRemembered() {
        let listener = StageRecordingListener()
        let router = makeRouter(listener: listener)
        router.handle(body: stageEnvelope(stageChanged(["stage": "under_review"])), sender: glomoFrame)

        router.deliverNativeClose(reason: GlomoCheckoutCloseReasons.userDismissed)

        XCTAssertEqual(listener.stages.map(\.stage), ["under_review"])
        XCTAssertTrue(listener.closes.isEmpty)
    }

    /// A bank page must not be able to invent a funnel, for the same reason it cannot invent a
    /// payment result: `message` is a privileged type and the origin gate owns it.
    func testAStageChangeFromAnUntrustedFrameIsDropped() {
        let listener = StageRecordingListener()
        let bankFrame = BridgeMessageSender(origin: "https://netbanking.bank.example", isMainFrame: true)

        makeRouter(listener: listener).handle(body: stageEnvelope(stageChanged()), sender: bankFrame)

        XCTAssertTrue(listener.stages.isEmpty)
    }
}

final class CheckoutEventParsingTests: XCTestCase {
    func testTheSegmentAndTheRawPayloadSurviveParsing() {
        let payload = stageChanged(["segment": ["index": 2, "total": 3]])

        let event = GlomoCheckoutStageChangedEvent(json: payload)

        XCTAssertEqual(event.segment, GlomoCheckoutSegment(index: 2, total: 3))
        XCTAssertEqual(event.rawPayload?["stage"], "customer_auth")
    }

    func testAMalformedPayloadParsesToEmptiesRatherThanFailing() {
        let event = GlomoCheckoutStageChangedEvent(json: ["stage": "opened"])

        XCTAssertEqual(event.version, 0)
        XCTAssertEqual(event.journeyId, "")
        XCTAssertEqual(event.resource.id, "")
        XCTAssertEqual(event.stage, "opened")
        XCTAssertNil(event.step)
    }

    func testAnEmptyOptionalReadsAsAbsentRatherThanAsAnEmptyString() {
        let event = GlomoCheckoutStageChangedEvent(json: stageChanged(["step": "", "provider": ""]))

        XCTAssertNil(event.step)
        XCTAssertNil(event.provider)
    }

    func testASegmentMissingABoundIsDroppedRatherThanHalfBuilt() {
        let event = GlomoCheckoutStageChangedEvent(json: stageChanged(["segment": ["index": 2]]))

        XCTAssertNil(event.segment)
    }

    func testAClosedPayloadParsesItsOptionalLastStep() {
        let event = GlomoCheckoutClosedEvent(json: [
            "v": 1,
            "resource": ["type": "order", "id": "order_1"],
            "journeyId": "jrn_1",
            "at": "2026-11-23T06:05:00.000Z",
            "flow": "payment",
            "reason": "confirmation_timeout",
        ])

        XCTAssertEqual(event.reason, "confirmation_timeout")
        XCTAssertNil(event.lastStage)
        XCTAssertNil(event.lastStep)
    }

    func testASynthesisedCloseOmitsWhatTheStageChangeDidNotCarry() {
        let bare = GlomoCheckoutStageChangedEvent(
            json: stageChanged(["method": nil, "paymentId": nil, "step": nil, "stage": "opened"])
        )

        let closed = bare.synthesisedClose(reason: "user_dismissed", at: "2026-11-23T07:00:00.000Z")

        XCTAssertNil(closed.method)
        XCTAssertNil(closed.paymentId)
        XCTAssertNil(closed.lastStep)
        XCTAssertEqual(closed.lastStage, "opened")
        XCTAssertEqual(closed.at, "2026-11-23T07:00:00.000Z")
    }
}

private final class StageRecordingListener: GlomoPayListener {
    var stages: [GlomoCheckoutStageChangedEvent] = []
    var closes: [GlomoCheckoutClosedEvent] = []
    var terminations: [TerminationSource] = []
    var successes: [GlomoPayPayload] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) {}
    func onSdkError(_ errors: [SdkError]) {}
    func onConnectionError(_ error: ConnectionError) {}
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) {}
    func onPaymentTerminate(_ source: TerminationSource) { terminations.append(source) }
    func onCheckoutStageChanged(_ event: GlomoCheckoutStageChangedEvent) { stages.append(event) }
    func onCheckoutClosed(_ event: GlomoCheckoutClosedEvent) { closes.append(event) }
}

private final class StageReporter: SDKErrorReporting, @unchecked Sendable {
    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) {}
}

private final class StageAnalytics: AnalyticsTracking {
    func track(_ event: String, properties: [String: Any?]) {}
    func updateFlowType(_ flowType: String) {}
}
