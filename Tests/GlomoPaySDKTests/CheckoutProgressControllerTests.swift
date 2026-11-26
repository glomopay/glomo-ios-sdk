#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import XCTest
@testable import GlomoPaySDK

/// Records what a merchant's listener would see, in one ordered log.
///
/// Ordering is part of the contract - the close is the last event of every checkout - and separate
/// per-callback arrays cannot express that.
final class OrderedCheckoutListener: GlomoPayListener {
    var log: [String] = []
    var onSuccess: ((GlomoPayPayload) -> Void)?

    func onPaymentSuccess(_ payload: GlomoPayPayload) {
        log.append("success")
        onSuccess?(payload)
    }

    func onPaymentFailure(_ payload: GlomoPayPayload) { log.append("failure") }
    func onSdkError(_ errors: [SdkError]) {}
    func onConnectionError(_ error: ConnectionError) {}
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) { log.append("journey_completed") }
    func onPaymentTerminate(_ source: TerminationSource) { log.append("terminate:\(source)") }
    func onCheckoutStageChanged(_ event: GlomoCheckoutStageChangedEvent) { log.append("stage:\(event.stage)") }

    func onCheckoutClosed(_ event: GlomoCheckoutClosedEvent) {
        log.append("closed:\(event.reason):\(event.lastStage ?? "nil")")
    }
}

/// The page's message sequences, replayed through a real checkout.
///
/// Router-level tests stub `onComplete`, which is the step that ends the checkout - so they can
/// assert sequences production never produces. Outcomes, ordering and closes belong here.
///
/// `swift test` builds for macOS, where the controller is compiled out, so this runs only on the
/// iOS-simulator job.
@MainActor
final class CheckoutProgressControllerTests: XCTestCase {
    private let telemetryRuntime = SDKTelemetryRuntime(
        configuration: .load(environment: [:], bundledValues: [:])
    )

    /// An origin the router's gate accepts; anything else is dropped and the test proves nothing.
    private let pageFrame = BridgeMessageSender(origin: "https://checkout.glomopay.com", isMainFrame: true)

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Presented for real: `handleResult` dismisses, and an unpresented controller makes that a
    /// no-op, which is the state production never reaches.
    private func makeController(
        listener: GlomoPayListener,
        autoClose: Bool = true,
        orderType: String = "lrs"
    ) -> GlomoPayCheckoutViewController {
        let config = GlomoPayConfig(
            publicKey: "test_public_key",
            orderId: "order_abc123",
            autoCloseOnConnectionError: autoClose
        )
        let controller = GlomoPayCheckoutViewController(
            config: config,
            orderType: orderType,
            listener: listener,
            apiClient: nil,
            telemetryRuntime: telemetryRuntime
        )
        controller.loadViewIfNeeded()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.present(controller, animated: false)
        self.window = window
        return controller
    }

    /// Loaded by path rather than `Bundle.module`: `Package.swift` is pinned by
    /// `PackageManifestTests` and this is how `Tests/Fixtures` is already read.
    private func sequence(_ name: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/checkout-sequences/\(name).json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(json as? [[String: Any]])
    }

    private func replay(_ name: String, into controller: GlomoPayCheckoutViewController) throws {
        for envelope in try sequence(name) {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            controller.eventRouter.handle(body: body, sender: pageFrame)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func post(_ envelope: [String: Any], into controller: GlomoPayCheckoutViewController) throws {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        controller.eventRouter.handle(body: body, sender: pageFrame)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func assertCloseIsLastAndSingle(_ log: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(log.filter { $0.hasPrefix("closed:") }.count, 1, "\(log)", file: file, line: line)
        if log.contains(where: { $0.hasPrefix("closed:") }) {
            XCTAssertTrue(log.last?.hasPrefix("closed:") == true, "close was not last: \(log)", file: file, line: line)
        }
    }

    private func stage(_ name: String, step: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "v": 1,
            "method": "lrs",
            "resource": ["type": "order", "id": "order_abc123"],
            "paymentId": "pay_abc123",
            "journeyId": "jrn_abc123",
            "at": "2026-11-23T06:00:00.000Z",
            "flow": "payment",
            "stage": name,
            "provider": "HDFC",
            "journeyType": "native",
        ]
        if let step { payload["step"] = step }
        return ["type": "message", "data": ["type": "checkout.stage_changed", "payload": payload]]
    }

    func testASuccessfulPaymentEndsWithACompletedCloseAfterTheOutcome() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)

        try replay("success", into: controller)

        XCTAssertEqual(
            listener.log,
            ["stage:awaiting_confirmation", "stage:confirmed", "success", "closed:completed:confirmed"]
        )
        assertCloseIsLastAndSingle(listener.log)
    }

    /// Today's page order, pinned as it is rather than as it should be: the page reports
    /// `payment.failure` before the `failed` stage, and nothing follows the close. Delete this
    /// with its fixture once the page sends `failed` first - the test below is the same journey
    /// in that order.
    func testADeclinedPaymentClosesAsAnErrorAndDropsTheStageBehindIt() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)

        try replay("decline-current", into: controller)

        XCTAssertEqual(
            listener.log,
            ["stage:awaiting_confirmation", "failure", "closed:error:awaiting_confirmation"]
        )
        assertCloseIsLastAndSingle(listener.log)
    }

    func testADeclinedPaymentQuotesTheFailedStageOnceThePageSendsItFirst() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)

        try replay("decline-fixed", into: controller)

        XCTAssertEqual(
            listener.log,
            ["stage:awaiting_confirmation", "stage:failed", "failure", "closed:error:failed"]
        )
        assertCloseIsLastAndSingle(listener.log)
    }

    /// `handle.close()` on the handle `startCheckout` returns calls exactly this.
    ///
    /// The host's close re-enters while the result is still being delivered, before `handleResult`
    /// has set `didTerminate`, so `onPaymentTerminate` runs for the close the host asked for. That
    /// is this SDK's existing rule - every termination is reported - and it differs from Flutter,
    /// which suppresses the callback once a result has gone out. The close is still single and
    /// still last, which is what the contract constrains.
    func testAHostClosingFromOnPaymentSuccessStillGetsExactlyOneClose() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)
        listener.onSuccess = { [weak controller] _ in controller?.closeCheckout() }

        try replay("success", into: controller)

        XCTAssertEqual(
            listener.log,
            [
                "stage:awaiting_confirmation",
                "stage:confirmed",
                "success",
                "terminate:programmatic",
                "closed:completed:confirmed",
            ]
        )
        assertCloseIsLastAndSingle(listener.log)
    }

    func testAPageCancelReportsTheTerminationAndThenThePagesOwnReason() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)

        try replay("page-cancel", into: controller)

        XCTAssertEqual(
            listener.log,
            ["stage:customer_auth", "terminate:userDismiss", "closed:user_cancelled:customer_auth"]
        )
        assertCloseIsLastAndSingle(listener.log)
    }

    func testACloseWithNoPayloadIsTheFlagBeingOffAndOnlyTerminates() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)

        try replay("flag-off-close", into: controller)

        XCTAssertEqual(listener.log, ["terminate:userDismiss"])
    }

    func testEmptyPayloadsDeliverNeitherCallback() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)

        try replay("empty-payload", into: controller)

        XCTAssertFalse(listener.log.contains { $0.hasPrefix("stage:") || $0.hasPrefix("closed:") }, "\(listener.log)")
    }

    func testASheetDismissAfterAConfirmedStageClosesAsCompleted() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)
        try post(stage("confirmed"), into: controller)

        controller.presentationControllerDidDismiss(UIPresentationController(
            presentedViewController: controller,
            presenting: nil
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(listener.log.last, "closed:completed:confirmed")
        assertCloseIsLastAndSingle(listener.log)
    }

    /// `orderType: "standard"` so the only WebView in the tree is the main one. An LRS checkout
    /// also builds the education carousel, and `didFailProvisionalNavigation` routes by identity -
    /// handing it the carousel reports a carousel failure and never shows the error screen.
    func testLeavingTheSdksOwnErrorScreenClosesAsAnError() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener, autoClose: false, orderType: "standard")
        try post(stage("customer_auth", step: "otp"), into: controller)

        let main = try XCTUnwrap(webViews(in: controller.view).first)
        controller.webView(
            main,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        )
        // Found by the action it carries, not by its title, so rewiring Cancel back to the plain
        // dismiss fails here rather than passing with the wrong reason.
        let cancel = try XCTUnwrap(
            buttons(in: controller.view).first { button in
                button.actions(forTarget: controller, forControlEvent: .touchUpInside)?
                    .contains("errorPanelCloseTapped") == true
            },
            "the error panel's Cancel was not in the view tree"
        )
        // Performed rather than sent: `UIControl.sendActions` does not dispatch without a running
        // application, and silently doing nothing is exactly how this test would pass vacuously.
        for action in cancel.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? [] {
            controller.perform(Selector(action))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(
            listener.log,
            ["stage:customer_auth", "terminate:connectionError", "closed:error:customer_auth"]
        )
        assertCloseIsLastAndSingle(listener.log)
    }

    func testACloseQuotesAStageTheSdkDoesNotRecogniseWhenThePageSentItLast() throws {
        let listener = OrderedCheckoutListener()
        let controller = makeController(listener: listener)
        try post(stage("customer_auth", step: "otp"), into: controller)
        try post(stage("teleported"), into: controller)

        controller.presentationControllerDidDismiss(UIPresentationController(
            presentedViewController: controller,
            presenting: nil
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(listener.log.last, "closed:user_dismissed:teleported")
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}
#endif
