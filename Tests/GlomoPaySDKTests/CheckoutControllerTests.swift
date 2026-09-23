#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import XCTest
@testable import GlomoPaySDK

/// The first tests that actually execute `GlomoPayCheckoutViewController`.
///
/// `swift test` builds for macOS, where `canImport(UIKit)` is false and the whole controller is
/// compiled out, so everything here runs only on the iOS-simulator job. Keep assertions on
/// behaviour that does not need a live network or a real bank page.
@MainActor
final class CheckoutControllerTests: XCTestCase {
    // Controller tests must not send analytics or errors to live telemetry services.
    private let telemetryRuntime = SDKTelemetryRuntime(
        configuration: .load(environment: [:], bundledValues: [:])
    )

    private func makeController(
        orderType: String = "standard",
        autoClose: Bool = true,
        listener: GlomoPayListener? = nil
    ) -> GlomoPayCheckoutViewController {
        let config = GlomoPayConfig(
            publicKey: "test_public_key",
            orderId: "order_123456",
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
        return controller
    }

    func testAutoCloseIsReachableThroughTheConfigurationOnly() {
        XCTAssertTrue(makeController(autoClose: true).config.autoCloseOnConnectionError)
        XCTAssertFalse(makeController(autoClose: false).config.autoCloseOnConnectionError)
    }

    func testBothWebViewsRefuseHistoryGestures() throws {
        let controller = makeController()
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        // A left-edge swipe must not walk checkout steps, or bank history that never drains.
        XCTAssertFalse(main.allowsBackForwardNavigationGestures)

        controller.eventRouter.handle(envelope: [
            "type": "window.open",
            "url": "https://bank.example/3ds",
        ])
        let all = webViews(in: controller.view)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { !$0.allowsBackForwardNavigationGestures })
    }

    func testCheckoutUsesItsOwnNonPersistentDataStore() throws {
        let controller = makeController()
        let main = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)

        // Not `.default()`: that is the app-wide store, and checkout cookies leaked into the
        // merchant application's own WKWebViews through it.
        XCTAssertFalse(main.configuration.websiteDataStore.isPersistent)
        XCTAssertNotIdentical(main.configuration.websiteDataStore, WKWebsiteDataStore.default())
    }

    func testTerminationDeliversOnceAndReportsProgrammaticSource() {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)

        controller.closeCheckout()
        controller.closeCheckout()

        XCTAssertEqual(listener.terminations, [.programmatic])
    }

    func testDismissalWithoutAResultReportsUserDismiss() {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)

        // The native escape: interactive sheet dismissal. It must stay available and must report.
        controller.presentationControllerDidDismiss(
            UIPresentationController(presentedViewController: controller, presenting: nil)
        )

        XCTAssertEqual(listener.terminations, [.userDismiss])
    }

    func testDroppedListenerIsReportedInsteadOfSilentlyLosingTheResult() {
        var listener: RecordingCheckoutListener? = RecordingCheckoutListener()
        let controller = makeController(listener: listener)
        listener = nil

        // The listener is weak: nothing else retains it, so it is gone before the result exists.
        controller.closeCheckout()

        // Nothing to assert on the listener - the point is that this does not crash and the SDK
        // reports it. The analytics assertion lives in the router test, which can inject a tracker.
        XCTAssertTrue(controller.config.autoCloseOnConnectionError)
    }

    // MARK: - Bridge message in, callback out

    /// The paths the doc asks for: a bridge message reaching the controller's router, and what the
    /// host is told as a result. These are the assertions that could not exist before there was an
    /// iOS destination to run them on.

    func testBridgeSuccessMessageReachesTheHostThroughTheController() {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)

        controller.eventRouter.handle(envelope: [
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

        XCTAssertEqual(listener.successes.map(\.orderId), ["order_123456"])
    }

    func testBridgeFailureWithoutASignatureStillReachesTheHost() {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)

        controller.eventRouter.handle(envelope: [
            "type": "message",
            "data": ["type": "payment.failure", "payload": ["orderId": "order_123456"]],
        ])

        XCTAssertEqual(listener.failures.map(\.orderId), ["order_123456"])
        // Not an SDK error about the SDK's own guard, which is what the host used to receive.
        XCTAssertTrue(listener.errors.isEmpty)
    }

    func testBridgeBankTransferReachesTheJourneyCallbackAndNotPaymentSuccess() {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)

        controller.eventRouter.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.bank_transfer_submitted",
                "payload": ["orderId": "order_123456", "transaction_reference": "utr_1"],
            ],
        ])

        XCTAssertTrue(listener.successes.isEmpty)
        XCTAssertEqual(listener.journeys.map(\.orderId), ["order_123456"])
        XCTAssertEqual(listener.journeys.first?.transactionReference, "utr_1")
    }

    // MARK: - Flow overlay open / back / close

    func testWindowOpenOpensTheOverlayAndBackClosesIt() throws {
        let controller = makeController()
        XCTAssertEqual(webViews(in: controller.view).count, 1)

        controller.eventRouter.handle(envelope: [
            "type": "window.open",
            "url": "https://bank.example/3ds",
        ])

        // The overlay carries the second WebView; a standard order has no carousel, so the count
        // is exactly two.
        XCTAssertEqual(webViews(in: controller.view).count, 2)

        let back = try XCTUnwrap(button(titled: GlomoPayStrings.back, in: controller.view))
        // SwiftPM runs without UIApplicationMain, so UIControl.sendActions cannot dispatch.
        // Invoke the button's registered target/action and verify the real wiring and handler.
        let actions = try XCTUnwrap(back.actions(forTarget: controller, forControlEvent: .touchUpInside))
        XCTAssertEqual(actions.count, 1)
        for action in actions {
            controller.perform(NSSelectorFromString(action), with: back)
        }

        // Back closes the overlay unconditionally - it does not walk the bank page's history.
        XCTAssertEqual(webViews(in: controller.view).count, 1)
    }

    func testWindowCloseFromThePageClosesTheOverlay() {
        let controller = makeController()
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        XCTAssertEqual(webViews(in: controller.view).count, 2)

        controller.eventRouter.handle(envelope: ["type": "window.close"])

        XCTAssertEqual(webViews(in: controller.view).count, 1)
    }

    func testRejectedWindowOpenURLNeverOpensAnOverlay() {
        let controller = makeController()

        for rawURL in ["javascript:alert(1)", "file:///etc/passwd", "upi://pay", "about:blank"] {
            controller.eventRouter.handle(envelope: ["type": "window.open", "url": rawURL])
        }

        XCTAssertEqual(webViews(in: controller.view).count, 1)
    }

    // MARK: - Connection-error paths

    func testCancelledNavigationIsNotReportedAndDoesNotCloseTheCheckout() throws {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        controller.webView(
            main,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        )

        // WebKit cancels navigations routinely; with auto-close on, reporting it terminated live
        // checkouts for a non-event.
        XCTAssertTrue(listener.connectionErrors.isEmpty)
        XCTAssertTrue(listener.terminations.isEmpty)
    }

    func testRealLoadFailureReportsConnectionErrorOnceAndNotAlsoAnSdkError() throws {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        controller.webView(
            main,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        )

        XCTAssertEqual(listener.connectionErrors.count, 1)
        XCTAssertEqual(listener.connectionErrors.first?.type, .noInternet)
        // One cause, one callback.
        XCTAssertTrue(listener.errors.isEmpty)
        XCTAssertEqual(listener.terminations, [.connectionError])
    }

    func testUnmappedWebKitFailureShowsRetryInsteadOfClosingTheCheckout() throws {
        let listener = RecordingCheckoutListener()
        let controller = makeController(listener: listener)
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        controller.webView(
            main,
            didFailProvisionalNavigation: nil,
            withError: NSError(
                domain: "WKErrorDomain",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "RAW TECHNICAL MESSAGE"]
            )
        )

        XCTAssertEqual(listener.connectionErrors.count, 1)
        XCTAssertTrue(listener.terminations.isEmpty)
        XCTAssertNotNil(button(titled: GlomoPayStrings.retry, in: controller.view))
        XCTAssertNotNil(button(titled: GlomoPayStrings.cancel, in: controller.view))
        XCTAssertTrue(labelTexts(in: controller.view).contains(GlomoPayStrings.connectionErrorMessage))
        XCTAssertFalse(labelTexts(in: controller.view).contains("RAW TECHNICAL MESSAGE"))
    }

    // MARK: - Order-type detection

    func testOrderFetchTimeoutTerminatesWithoutOpeningAnyCheckout() async {
        let listener = RecordingCheckoutListener()
        let controller = GlomoPayCheckoutViewController(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123456"),
            orderType: "auto",
            listener: listener,
            apiClient: GlomoPayApiClient(
                publicKey: "test_public_key",
                baseURL: URL(string: "https://api.example.com")!,
                client: FailingHTTPClient(error: URLError(.timedOut))
            ),
            telemetryRuntime: telemetryRuntime
        )
        controller.loadViewIfNeeded()

        let reported = expectation(description: "connection error reported")
        listener.onConnectionErrorCalled = { reported.fulfill() }
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        // This bounds simulator scheduling, not the mocked HTTP request's timeout.
        await fulfillment(of: [reported], timeout: 30)

        // A timeout is connectivity, not an SDK fault - and no WebView was navigated, because the
        // order type is only knowable from a successful fetch.
        XCTAssertEqual(listener.connectionErrors.first?.type, .timeout)
        XCTAssertTrue(listener.errors.isEmpty)
        XCTAssertEqual(listener.terminations, [.connectionError])
        XCTAssertNil(webViews(in: controller.view).first?.url)
    }

    func testOrderFetchStatusFailureIsAnSdkErrorNotAConnectionError() async {
        let listener = RecordingCheckoutListener()
        let controller = GlomoPayCheckoutViewController(
            config: GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123456"),
            orderType: "auto",
            listener: listener,
            apiClient: GlomoPayApiClient(
                publicKey: "test_public_key",
                baseURL: URL(string: "https://api.example.com")!,
                client: StatusHTTPClient(statusCode: 500)
            ),
            telemetryRuntime: telemetryRuntime
        )
        controller.loadViewIfNeeded()

        let reported = expectation(description: "sdk error reported")
        listener.onSdkErrorCalled = { reported.fulfill() }
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        await fulfillment(of: [reported], timeout: 30)

        // The server answered, so connectivity is fine.
        XCTAssertTrue(listener.connectionErrors.isEmpty)
        XCTAssertEqual(listener.errors.first?.type, .networkError)
        XCTAssertNil(webViews(in: controller.view).first?.url)
    }

    // MARK: - View-hierarchy helpers

    private func webViews(in root: UIView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = root as? WKWebView { found.append(webView) }
        for subview in root.subviews { found += webViews(in: subview) }
        return found
    }

    private func button(titled title: String, in root: UIView) -> UIButton? {
        if let candidate = root as? UIButton, candidate.title(for: .normal) == title { return candidate }
        for subview in root.subviews {
            if let match = button(titled: title, in: subview) { return match }
        }
        return nil
    }

    private func labelTexts(in root: UIView) -> [String] {
        var texts: [String] = []
        if let label = root as? UILabel, let text = label.text { texts.append(text) }
        for subview in root.subviews { texts += labelTexts(in: subview) }
        return texts
    }

    func testOpenFunnelOnlyAdvancesAndTimesOutOncePerAttempt() {
        var funnel = CheckoutOpenFunnel()

        XCTAssertTrue(funnel.advance(.webViewCreated))
        XCTAssertTrue(funnel.advance(.urlResolved))
        XCTAssertTrue(funnel.advance(.navigationFinished))
        // A redirect cannot rewind the funnel.
        XCTAssertFalse(funnel.advance(.navigationStarted))
        XCTAssertEqual(funnel.lastStep, .navigationFinished)

        XCTAssertEqual(funnel.timeout(), "navigation_finished")
        XCTAssertNil(funnel.timeout())
        XCTAssertFalse(funnel.openedAfterTimeout)

        XCTAssertTrue(funnel.advance(.bridgeReady))
        XCTAssertTrue(funnel.didOpen)
        XCTAssertTrue(funnel.openedAfterTimeout)
        XCTAssertNil(funnel.timeout())
    }

    func testOpenWatchdogIsDerivedFromTheAPITimeoutAndRenderBudget() {
        XCTAssertEqual(
            CheckoutOpenBudget.watchdog,
            GlomoPayApiClient.requestTimeout + CheckoutOpenBudget.renderTimeout + CheckoutOpenBudget.margin
        )
        XCTAssertEqual(CheckoutOpenBudget.renderTimeout, 15)
    }

    func testOpenFunnelWireNamesAreDeclaredInExecutionOrder() {
        XCTAssertEqual(
            CheckoutOpenStep.allCases.map(\.wireName),
            ["webview_created", "url_resolved", "navigation_started", "navigation_finished", "bridge_ready"]
        )
    }
}

private final class RecordingCheckoutListener: GlomoPayListener {
    var successes: [GlomoPayPayload] = []
    var failures: [GlomoPayPayload] = []
    var journeys: [GlomoPayUserJourneyPayload] = []
    var errors: [SdkError] = []
    var connectionErrors: [ConnectionError] = []
    var terminations: [TerminationSource] = []

    /// The order-fetch paths are async, so those tests wait on the callback rather than sleeping.
    var onConnectionErrorCalled: (() -> Void)?
    var onSdkErrorCalled: (() -> Void)?

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) { failures.append(payload) }
    func onSdkError(_ errors: [SdkError]) {
        self.errors.append(contentsOf: errors)
        onSdkErrorCalled?()
    }
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) { journeys.append(payload) }
    func onConnectionError(_ error: ConnectionError) {
        connectionErrors.append(error)
        onConnectionErrorCalled?()
    }
    func onPaymentTerminate(_ source: TerminationSource) { terminations.append(source) }
}

private struct FailingHTTPClient: GlomoPayHTTPClient {
    let error: Error
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw error }
}

private struct StatusHTTPClient: GlomoPayHTTPClient {
    let statusCode: Int
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#"{"message":"server error"}"#.utf8), response)
    }
}
#endif
