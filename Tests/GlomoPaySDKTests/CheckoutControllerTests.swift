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
        listener: GlomoPayListener? = nil,
        analyticsTransport: AnalyticsTransporting? = nil,
        apiClient: GlomoPayApiClient? = nil
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
            apiClient: apiClient,
            telemetryRuntime: analyticsTransport.map {
                SDKTelemetryRuntime(
                    configuration: .load(environment: [:], bundledValues: [:]),
                    mixpanelTransport: $0
                )
            } ?? telemetryRuntime
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
        // reports it. The analytics assertion is testOutcomeWithAReleasedListenerReportsHadListenerFalse.
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

    // MARK: - Loading teardown

    /// On a successful load, only `markBridgeReady()` hides the loading view, and reaching it takes
    /// didFinish -> the page's bridge-ready hook -> bridge() -> script message handler -> router ->
    /// onBridgeReady. The iOS test run has no app host, so a real WebView never loads a page or runs
    /// a script here: these drive the delegate directly, as the connection-error tests do, and read
    /// the JavaScript call through `scriptEvaluator`. The hook's page side is pinned in
    /// ContractCoverageTests.

    func testMainWebViewFinishAsksForBridgeReadyAndKeepsTheSpinnerUntilItArrives() throws {
        let controller = makeController()
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        var evaluated: [String] = []
        controller.scriptEvaluator = { webView, script in
            XCTAssertIdentical(webView, main)
            evaluated.append(script)
        }

        controller.webView(main, didStartProvisionalNavigation: nil)
        controller.webView(main, didFinish: nil)

        XCTAssertEqual(evaluated, [GlomoPayInjectionScripts.sendBridgeReadyAfterNativeLoad])
        // Navigation has finished, but the page has not reported ready, so the spinner must stay.
        XCTAssertFalse(controller.loadingView.isHidden)

        controller.eventRouter.handle(envelope: ["type": "bridge.ready"])

        // Without this, the spinner stays over a working page until the render watchdog reports
        // "taking longer than expected".
        XCTAssertTrue(controller.loadingView.isHidden)
    }

    func testFlowWebViewFinishDoesNotAskForBridgeReady() throws {
        let controller = makeController()
        var evaluated: [String] = []
        controller.scriptEvaluator = { _, script in evaluated.append(script) }
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        let flow = try XCTUnwrap(webViews(in: controller.view).first { $0 !== main })

        controller.webView(flow, didFinish: nil)

        // bridge.ready is the main checkout's signal; a bank page finishing must not clear it.
        XCTAssertTrue(evaluated.isEmpty)
        XCTAssertFalse(controller.loadingView.isHidden)
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

    // MARK: - Journey id

    func testSDKLoadedFiresOncePerOpenAndARetryKeepsTheJourneyID() async throws {
        let listener = RecordingCheckoutListener()
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(listener: listener, analyticsTransport: transport)

        present(controller)
        let url = try await loadedURL(of: controller)
        let journeyID = try XCTUnwrap(checkoutJourneyID(in: url))

        let main = try XCTUnwrap(webViews(in: controller.view).first)
        controller.webView(
            main,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: "WKErrorDomain", code: 3, userInfo: nil)
        )
        try tap(GlomoPayStrings.retry, in: controller)
        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkCTAClicked, count: 1)
        try await settle()
        let loaded = await transport.allEvents(named: AnalyticsEventName.sdkLoaded)
        let events = await transport.recordedEvents()

        XCTAssertEqual(controller.currentURL, url)
        XCTAssertEqual(journeyID, journeyID.lowercased())
        XCTAssertNotNil(UUID(uuidString: journeyID))
        XCTAssertEqual(loaded.count, 1)
        let properties = try XCTUnwrap(loaded.first).jsonProperties
        XCTAssertEqual(properties["integration"] as? String, "ios_sdk")
        XCTAssertEqual(properties["sdk_version"] as? String, GlomoPaySDKBuild.version)
        XCTAssertEqual(properties["platform"] as? String, "ios")
        XCTAssertEqual(properties["$os"] as? String, "iOS")
        XCTAssertNotNil(properties["$os_version"] as? String)
        XCTAssertNotNil(properties["$model"] as? String)
        for event in events {
            let properties = event.jsonProperties
            XCTAssertTrue(AnalyticsCatalogue.eventNames.contains(event.name), event.name)
            XCTAssertEqual(properties["journey_id"] as? String, journeyID)
            XCTAssertEqual(properties["$device_id"] as? String, journeyID)
            XCTAssertEqual(properties["distinct_id"] as? String, "$device:\(journeyID)")
            XCTAssertEqual(properties["resource_id"] as? String, "order_123456")
            XCTAssertEqual(properties["integration"] as? String, "ios_sdk")
            for freeText in Self.freeTextKeys {
                XCTAssertNil(properties[freeText], "\(event.name) carries \(freeText)")
            }
        }
    }

    func testEachOpenGetsItsOwnJourneyID() async throws {
        let firstTransport = RecordingAnalyticsTransport()
        let secondTransport = RecordingAnalyticsTransport()
        let first = makeController(analyticsTransport: firstTransport)
        let second = makeController(analyticsTransport: secondTransport)

        for controller in [first, second] {
            present(controller)
        }
        let firstURL = try await loadedURL(of: first)
        let secondURL = try await loadedURL(of: second)
        let firstID = try XCTUnwrap(checkoutJourneyID(in: firstURL))
        let secondID = try XCTUnwrap(checkoutJourneyID(in: secondURL))
        let firstLoaded = try await firstTransport.waitForEvents(named: AnalyticsEventName.sdkLoaded, count: 1)
        let secondLoaded = try await secondTransport.waitForEvents(named: AnalyticsEventName.sdkLoaded, count: 1)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(firstLoaded.map { $0.jsonProperties["journey_id"] as? String }, [firstID])
        XCTAssertEqual(secondLoaded.map { $0.jsonProperties["journey_id"] as? String }, [secondID])
    }

    func testLifecycle() async throws {
        let listener = RecordingCheckoutListener()
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(autoClose: false, listener: listener, analyticsTransport: transport)
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        for _ in 0..<2 {
            controller.webView(
                main,
                didFailProvisionalNavigation: nil,
                withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
            )
        }
        for _ in 0..<2 {
            controller.eventRouter.handle(envelope: ["type": "bridge.ready"])
        }
        controller.closeCheckout()
        controller.closeCheckout()

        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutClosed, count: 1)
        try await settle()
        let failed = await transport.allEvents(named: AnalyticsEventName.sdkCheckoutFailed)
        let viewed = await transport.allEvents(named: AnalyticsEventName.sdkPageViewed)
        let closed = await transport.allEvents(named: AnalyticsEventName.sdkCheckoutClosed)

        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.jsonProperties["error_code"] as? String, "connection_error")
        XCTAssertEqual(failed.first?.jsonProperties["error_detail"] as? String, "network")
        XCTAssertEqual(pageNames(of: viewed).filter { $0 == "checkout" }.count, 1)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.jsonProperties["trigger"] as? String, "merchant")
        XCTAssertEqual(closed.first?.jsonProperties["page_name"] as? String, "checkout")
        XCTAssertNil(closed.first?.jsonProperties["payment_event"])
        XCTAssertEqual(listener.terminations, [.programmatic])
    }

    func testCheckoutIsViewedOncePerJourneyAndLaterFailuresAreActionFailures() async throws {
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(autoClose: false, analyticsTransport: transport)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)

        controller.eventRouter.handle(envelope: ["type": "bridge.ready"])
        controller.webView(main, didFailProvisionalNavigation: nil, withError: offline)
        try tap(GlomoPayStrings.retry, in: controller)
        controller.eventRouter.handle(envelope: ["type": "bridge.ready"])
        controller.webView(main, didFailProvisionalNavigation: nil, withError: offline)

        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkActionFailed, count: 2)
        try await settle()
        let viewed = await transport.allEvents(named: AnalyticsEventName.sdkPageViewed)
        let failed = await transport.allEvents(named: AnalyticsEventName.sdkCheckoutFailed)

        XCTAssertEqual(pageNames(of: viewed).filter { $0 == "checkout" }.count, 1)
        XCTAssertFalse(failed.contains { $0.jsonProperties["error_code"] as? String == "connection_error" })
    }

    func testUserDismissOnTheSpinnerIsAUserDismissCloseOnTheLoadingPage() async throws {
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(analyticsTransport: transport)

        controller.presentationControllerDidDismiss(
            UIPresentationController(presentedViewController: controller, presenting: nil)
        )

        let closed = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutClosed, count: 1)
        XCTAssertEqual(closed.first?.jsonProperties["trigger"] as? String, "user_dismiss")
        XCTAssertEqual(closed.first?.jsonProperties["page_name"] as? String, "loading")
    }

    func testOutcomeIsOneCloseWithThePaymentEventAndNoPaymentEvent() async throws {
        let listener = RecordingCheckoutListener()
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(listener: listener, analyticsTransport: transport)

        controller.eventRouter.handle(envelope: ["type": "bridge.ready"])
        controller.eventRouter.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": ["orderId": "order_123456", "paymentId": "pay_123456", "signature": "signed"],
            ],
        ])
        controller.closeCheckout()

        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutClosed, count: 1)
        try await settle()
        let closed = await transport.allEvents(named: AnalyticsEventName.sdkCheckoutClosed)
        let events = await transport.recordedEvents()

        XCTAssertEqual(listener.successes.map(\.orderId), ["order_123456"])
        XCTAssertEqual(closed.count, 1)
        let properties = try XCTUnwrap(closed.first).jsonProperties
        XCTAssertEqual(properties["trigger"] as? String, "sdk")
        XCTAssertEqual(properties["payment_event"] as? String, "payment_success")
        XCTAssertEqual(properties["had_listener"] as? Bool, true)
        XCTAssertEqual(properties["page_name"] as? String, "checkout")
        XCTAssertTrue(events.allSatisfy { AnalyticsCatalogue.eventNames.contains($0.name) })
        XCTAssertTrue(listener.terminations.isEmpty)
    }

    func testOutcomeWithAReleasedListenerReportsHadListenerFalse() async throws {
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(analyticsTransport: transport)

        controller.eventRouter.handle(envelope: [
            "type": "message",
            "data": ["type": "payment.failure", "payload": ["orderId": "order_123456"]],
        ])

        let closed = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutClosed, count: 1)
        XCTAssertEqual(closed.first?.jsonProperties["payment_event"] as? String, "payment_failure")
        XCTAssertEqual(closed.first?.jsonProperties["had_listener"] as? Bool, false)
        XCTAssertEqual(closed.first?.jsonProperties["page_name"] as? String, "loading")
    }

    func testNativeControls() async throws {
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(autoClose: false, analyticsTransport: transport)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)

        controller.eventRouter.handle(envelope: ["type": "bridge.ready"])
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        let flow = try XCTUnwrap(webViews(in: controller.view).first { $0 !== main })
        controller.webView(flow, didFailProvisionalNavigation: nil, withError: offline)
        try tap(GlomoPayStrings.retry, in: controller)
        try tap(GlomoPayStrings.back, in: controller)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        controller.eventRouter.handle(envelope: ["type": "window.close"])
        controller.webView(main, didFailProvisionalNavigation: nil, withError: offline)
        try tap(GlomoPayStrings.retry, in: controller)

        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkCTAClicked, count: 3)
        _ = try await transport.waitForEvents(named: AnalyticsEventName.sdkPageViewed, count: 5)
        try await settle()
        let ctas = await transport.allEvents(named: AnalyticsEventName.sdkCTAClicked)
        let viewed = await transport.allEvents(named: AnalyticsEventName.sdkPageViewed)
        let submitted = await transport.allEvents(named: AnalyticsEventName.sdkActionSubmitted)
        let failed = await transport.allEvents(named: AnalyticsEventName.sdkActionFailed)

        XCTAssertEqual(
            ctas.map { "\($0.jsonProperties["cta_name"] as? String ?? "")@\($0.jsonProperties["page_name"] as? String ?? "")" }
                .sorted(),
            ["back_to_checkout@bank_redirect", "retry@error", "retry@error"]
        )
        XCTAssertEqual(
            pageNames(of: viewed).sorted(),
            ["bank_redirect", "bank_redirect", "checkout", "error", "error"]
        )
        XCTAssertTrue(viewed.filter { $0.jsonProperties["page_name"] as? String == "error" }.allSatisfy {
            $0.jsonProperties["error_code"] as? String == "connection_error"
        })
        XCTAssertEqual(
            viewed.first { $0.jsonProperties["page_name"] as? String == "bank_redirect" }?
                .jsonProperties["url_origin"] as? String,
            "https://bank.example"
        )
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.jsonProperties["action_name"] as? String, "bank_redirect")
        XCTAssertEqual(
            failed.map { $0.jsonProperties["webview_type"] as? String ?? "" }.sorted(),
            ["flow", "main"]
        )
        XCTAssertTrue(failed.allSatisfy {
            $0.jsonProperties["action_name"] as? String == "webview_load"
                && $0.jsonProperties["error_code"] as? String == "connection_error"
        })
    }

    // MARK: - Order-type detection

    func testOrderFetch() async throws {
        let listener = RecordingCheckoutListener()
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(
            orderType: "auto",
            listener: listener,
            analyticsTransport: transport,
            apiClient: GlomoPayApiClient(
                publicKey: "test_public_key",
                baseURL: URL(string: "https://api.example.com")!,
                client: StatusHTTPClient(statusCode: 500)
            )
        )

        let reported = expectation(description: "sdk error reported")
        listener.onSdkErrorCalled = { reported.fulfill() }
        present(controller)
        await fulfillment(of: [reported], timeout: 30)
        let api = try await transport.waitForEvents(named: AnalyticsEventName.sdkAPIBackend, count: 1)
        let failed = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutFailed, count: 1)
        let closed = try await transport.waitForEvents(named: AnalyticsEventName.sdkCheckoutClosed, count: 1)

        let apiProperties = try XCTUnwrap(api.first).jsonProperties
        let apiPath = try XCTUnwrap(apiProperties["api_path"] as? String)
        XCTAssertEqual(apiPath, "/api/public/v1/order/:order_id")
        XCTAssertFalse(apiPath.contains("order_123456"))
        XCTAssertEqual(apiProperties["http_method"] as? String, "GET")
        XCTAssertEqual(apiProperties["status"] as? String, "failed")
        XCTAssertEqual(apiProperties["error_code"] as? String, "http_error")
        XCTAssertEqual(apiProperties["http_status"] as? Int64, 500)
        XCTAssertEqual(failed.first?.jsonProperties["error_code"] as? String, "order_fetch_failed")
        XCTAssertEqual(failed.first?.jsonProperties["error_detail"] as? String, "http_5xx")
        XCTAssertEqual(closed.first?.jsonProperties["trigger"] as? String, "sdk")
    }

    func testOrderFetchSuccessIsOneSucceededAPIEvent() async throws {
        let transport = RecordingAnalyticsTransport()
        let controller = makeController(
            orderType: "auto",
            analyticsTransport: transport,
            apiClient: GlomoPayApiClient(
                publicKey: "test_public_key",
                baseURL: URL(string: "https://api.example.com")!,
                client: StatusHTTPClient(statusCode: 200)
            )
        )

        present(controller)
        _ = try await loadedURL(of: controller)
        let api = try await transport.waitForEvents(named: AnalyticsEventName.sdkAPIBackend, count: 1)

        let properties = try XCTUnwrap(api.first).jsonProperties
        XCTAssertEqual(properties["status"] as? String, "succeeded")
        XCTAssertEqual(properties["http_status"] as? Int64, 200)
        XCTAssertEqual(properties["api_path"] as? String, "/api/public/v1/order/:order_id")
        XCTAssertEqual(properties["journey"] as? String, "standard")
        XCTAssertNil(properties["error_code"])
    }

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

    private static let freeTextKeys = [
        "error_message", "error_description", "reason", "message", "data", "url", "checkout_url", "errors",
    ]

    private func present(_ controller: GlomoPayCheckoutViewController) {
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
    }

    private func loadedURL(of controller: GlomoPayCheckoutViewController) async throws -> URL {
        for _ in 0..<600 where controller.currentURL == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try XCTUnwrap(controller.currentURL)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func tap(_ title: String, in controller: GlomoPayCheckoutViewController) throws {
        let control = try XCTUnwrap(button(titled: title, in: controller.view), title)
        for action in try XCTUnwrap(control.actions(forTarget: controller, forControlEvent: .touchUpInside)) {
            controller.perform(NSSelectorFromString(action), with: control)
        }
    }

    private func pageNames(of events: [AnalyticsEvent]) -> [String] {
        events.map { $0.jsonProperties["page_name"] as? String ?? "" }
    }

    private func checkoutJourneyID(in url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "journeyId" }?.value
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
