#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// Native iOS host for the main GlomoPay checkout document.
///
/// The JavaScript message bridge is deliberately attached in the next phase;
/// this controller owns only presentation, navigation, loading, and network
/// error behavior so those concerns stay independently testable.
public final class GlomoPayCheckoutViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    public let config: GlomoPayConfig
    public let requestedOrderType: String
    public weak var listener: GlomoPayListener?

    private let apiClient: GlomoPayApiClient
    private let sessionID: String
    private let analytics: AnalyticsTracking
    private let errorReporter: SDKErrorReporting
    private var webView: WKWebView!
    private var flowWebView: WKWebView?
    private var flowOverlay: UIView?
    private var flowLoadingView: UIView?
    private var flowProgressView: UIProgressView?
    private var flowErrorView: UIView?
    private var progressView: UIProgressView!
    private var loadingView: UIView!
    private var loadingLabel: UILabel!
    private var errorView: UIView?
    private var currentURL: URL?
    private var didRetryMainDocument = false
    private var didRetryAfterProcessTermination = false
    private var didTerminate = false
    private var didTrackSDKInitialization = false
    private var progressObservation: NSKeyValueObservation?
    private var bridgeHandler: GlomoPayJavaScriptBridge?
    private var flowBridgeHandler: GlomoPayJavaScriptBridge?
    private var carouselWebView: WKWebView?
    private var carouselBridgeHandler: GlomoPayJavaScriptBridge?
    private var carouselContainer: UIView?
    private var carouselState: EducationCarouselState = .pending
    private var carouselFractionConstraint: NSLayoutConstraint?
    private var carouselZeroConstraint: NSLayoutConstraint?
    private var toolbarFractionConstraint: NSLayoutConstraint?
    private var toolbarFixedConstraint: NSLayoutConstraint?
    /// Internal, not private, so host-based tests can put a bridge message onto the real path -
    /// router in, controller behaviour out - instead of asserting against a parallel fake. It is
    /// not part of the public surface: `@testable import` reaches internal, merchants do not.
    var eventRouter: GlomoPayEventRouter!
    private var performanceSnapshotCollector: DevicePerformanceSnapshotCollector?
    private var networkSnapshotCollector: IOSNetworkPathSnapshotCollector?
    private var didStartCheckout = false
    private var openFunnel = CheckoutOpenFunnel()
    private var openStartedAt: Date?
    private var openWatchdog: Task<Void, Never>?
    private var renderWatchdog: Task<Void, Never>?
    var flowTypeState: CheckoutFlowTypeState

    /// One non-persistent store, shared by the main, flow and carousel WebViews.
    ///
    /// Shared because the 3DS redirect chain depends on it: the bank sets cookies in the flow
    /// WebView that the checkout document reads back. Non-persistent because `.default()` is the
    /// app-wide store, so checkout cookies, localStorage and cache leaked into the merchant
    /// application's own WKWebViews and back, and a second checkout started against whatever the
    /// first one left behind. This dies with the controller, which is why nothing has to be
    /// cleared at start or teardown - and why nothing clears app-wide state, which would destroy
    /// the 3DS session mid-redirect.
    private let checkoutDataStore = WKWebsiteDataStore.nonPersistent()

    public convenience init(
        config: GlomoPayConfig,
        orderType: String = "auto",
        listener: GlomoPayListener? = nil,
        apiClient: GlomoPayApiClient? = nil
    ) {
        self.init(
            config: config,
            orderType: orderType,
            listener: listener,
            apiClient: apiClient,
            telemetryRuntime: .shared
        )
    }

    init(
        config: GlomoPayConfig,
        orderType: String,
        listener: GlomoPayListener?,
        apiClient: GlomoPayApiClient?,
        telemetryRuntime: SDKTelemetryRuntime
    ) {
        let normalizedOrderType = orderType.lowercased()
        let sessionID = UUID().uuidString.lowercased()
        let errorReporter = SDKErrorReporterFactory.create(
            config: config,
            sessionID: sessionID,
            flowType: normalizedOrderType,
            runtime: telemetryRuntime
        )
        self.config = config
        self.requestedOrderType = normalizedOrderType
        self.flowTypeState = CheckoutFlowTypeState(requestedOrderType: normalizedOrderType)
        self.listener = listener
        self.apiClient = apiClient ?? GlomoPayApiClient(publicKey: config.publicKey)
        self.sessionID = sessionID
        self.errorReporter = errorReporter
        self.analytics = AnalyticsFactory.create(
            config: config,
            sessionID: sessionID,
            flowType: normalizedOrderType,
            errorReporter: errorReporter,
            runtime: telemetryRuntime
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            sheetPresentationController?.prefersGrabberVisible = true
            sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        performanceSnapshotCollector = DevicePerformanceSnapshot.makeCollector()
        view.backgroundColor = .systemBackground
        eventRouter = GlomoPayEventRouter(
            listener: listener,
            devMode: SDKBuildFlags.internalBuild,
            onComplete: { [weak self] result in self?.handleResult(result) },
            onWindowOpen: { [weak self] url in self?.openFlow(url) },
            onWindowClose: { [weak self] in self?.closeFlow() },
            onBridgeReady: { [weak self] in self?.markBridgeReady() },
            analytics: analytics,
            errorReporter: errorReporter
        )
        configureWebView()
        configureLoadingView()
        configureNavigationBar()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        navigationController?.presentationController?.delegate = self
        if currentURL == nil && errorView == nil {
            startCheckout()
        }
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if !didTerminate {
            terminate(source: .userDismiss)
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        progressObservation?.invalidate()
    }

    deinit {
        progressObservation?.invalidate()
        performanceSnapshotCollector?.restoreBatteryMonitoring()
    }

    private func configureWebView() {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = checkoutDataStore
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.bootstrap(devMode: SDKBuildFlags.internalBuild),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.credentialedRequestsFix,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.iosInputZoomFix,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.iosViewportFitFix,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.main,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        bridgeHandler = GlomoPayJavaScriptBridge { [weak self] body in
            DispatchQueue.main.async { self?.eventRouter.handle(body: body) }
        }
        if let bridgeHandler {
            userContentController.add(bridgeHandler, name: "GlomoPayBridge")
        }
        webConfiguration.userContentController = userContentController
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        advanceOpenStep(.webViewCreated)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // A left-edge swipe would walk the checkout web app back through steps it does not
        // expect to be re-entered, and the same gesture on a bank page walks history that never
        // drains. Neither WebView gets it.
        webView.allowsBackForwardNavigationGestures = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progressView?.progress = Float(webView.estimatedProgress)
            }
        }
    }

    private func configureLoadingView() {
        loadingView = UIView()
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.backgroundColor = .systemBackground

        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        loadingView.addSubview(indicator)

        loadingLabel = UILabel()
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.text = GlomoPayStrings.loadingCheckout
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.textAlignment = .center
        loadingView.addSubview(loadingLabel)

        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            indicator.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -16),
            loadingLabel.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 12),
            loadingLabel.leadingAnchor.constraint(equalTo: loadingView.leadingAnchor, constant: 24),
            loadingLabel.trailingAnchor.constraint(equalTo: loadingView.trailingAnchor, constant: -24),
        ])

        progressView = UIProgressView(progressViewStyle: .default)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = view.tintColor
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    private func configureNavigationBar() {
        navigationItem.title = GlomoPayStrings.checkoutTitle
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
    }

    private func startCheckout() {
        guard !didStartCheckout else { return }
        didStartCheckout = true
        startOpenWatchdog()
        continueCheckout()
        startNetworkSnapshotCollection()
    }

    // MARK: - Checkout-open funnel

    private func advanceOpenStep(_ step: CheckoutOpenStep) {
        guard openFunnel.advance(step) else { return }
        switch step {
        case .webViewCreated:
            analytics.track(AnalyticsEventName.checkoutWebViewCreated, properties: ["step": step.wireName])
        case .bridgeReady:
            analytics.track(AnalyticsEventName.checkoutBridgeReady, properties: ["step": step.wireName])
        case .urlResolved, .navigationStarted, .navigationFinished:
            // Already reported by their own navigation events; the funnel only records them.
            break
        }
    }

    /// The outer budget: nothing behind the spinner used to clear it, so a page that never
    /// rendered left the user waiting with no error, no retry and no callback.
    private func startOpenWatchdog() {
        openStartedAt = Date()
        openWatchdog?.cancel()
        let budget = CheckoutOpenBudget.watchdog
        openWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.didTerminate else { return }
            self.reportOpenTimeout(reason: "watchdog", budget: budget)
        }
    }

    /// Advisory by design: it reports and offers retry, and does not close the checkout, because
    /// the page may be seconds away and `autoCloseOnConnectionError` defaults to true.
    private func startRenderWatchdog() {
        renderWatchdog?.cancel()
        let budget = CheckoutOpenBudget.renderTimeout
        renderWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.didTerminate, !self.openFunnel.didOpen else { return }
            self.reportOpenTimeout(reason: "render_timeout", budget: budget)
            self.deliverConnectionError(ConnectionError(
                type: .timeout,
                message: "Checkout is taking longer than expected. You can retry or close checkout.",
                failedURL: self.currentURL,
                shouldAutoClose: false
            ))
        }
    }

    private func reportOpenTimeout(reason: String, budget: TimeInterval) {
        guard let lastStep = openFunnel.timeout() else { return }
        analytics.track(AnalyticsEventName.checkoutOpenTimeout, properties: [
            "last_step": lastStep,
            "reason": reason,
            "timeout_ms": Int(budget * 1_000),
            "elapsed_ms": openStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) },
        ])
    }

    private func markBridgeReady() {
        advanceOpenStep(.bridgeReady)
        if openFunnel.openedAfterTimeout {
            analytics.track(AnalyticsEventName.checkoutOpenedAfterTimeout, properties: [
                "elapsed_ms": openStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) },
            ])
        }
        cancelOpenWatchdogs()
        loadingView.isHidden = true
        progressView.isHidden = true
        errorView?.removeFromSuperview()
        errorView = nil
    }

    private func cancelOpenWatchdogs() {
        openWatchdog?.cancel()
        renderWatchdog?.cancel()
        openWatchdog = nil
        renderWatchdog = nil
    }

    private func startNetworkSnapshotCollection() {
        guard !didTerminate else { return }
        let collector = IOSAnalyticsProperties.makeNetworkSnapshotCollector()
        networkSnapshotCollector = collector
        collector.collect { [weak self] networkProperties in
            DispatchQueue.main.async {
                guard let self, !self.didTerminate else { return }
                self.networkSnapshotCollector = nil
                self.analytics.updateNetworkSnapshotProperties(networkProperties)
            }
        }
    }

    private func continueCheckout() {
        if !didTrackSDKInitialization {
            didTrackSDKInitialization = true
            var properties = performanceSnapshotCollector?.collect()
                ?? DevicePerformanceSnapshot.emptyProperties
            analytics.track(AnalyticsEventName.sdkInitialized, properties: properties)
        }
        let errors = Validator.validate(config: config)
        guard errors.isEmpty else {
            analytics.track(AnalyticsEventName.sdkValidationFailed, properties: [
                "failure_reason": validationFailureReason(errors.first),
                "error_message": errors.first?.message,
            ])
            deliverSdkErrors(errors)
            return
        }

        let compliance = DeviceComplianceChecker().check(
            strict: CompliancePolicy.requiresStrictCheck(config)
        )
        analytics.track(
            AnalyticsEventName.deviceComplianceChecked,
            properties: ComplianceAnalyticsProperties.make(result: compliance)
        )
        guard compliance.isCompliant else {
            let blockReason = compliance.isDebuggerAttached ? "debugger_attached" : "jailbreak_detected"
            analytics.track(AnalyticsEventName.deviceComplianceBlocked, properties: ["block_reason": blockReason])
            let message = compliance.isDebuggerAttached
                ? "Device is being debugged."
                : "Device is rooted or jailbroken."
            let errors = [SdkError(type: .deviceForbidden, message: message)]
            deliverSdkErrors(errors)
            return
        }

        loadingView.isHidden = false
        Task { [weak self] in
            guard let self else { return }
            guard let type = await self.resolveOrderType() else { return }
            guard !self.didTerminate else { return }
            guard let url = ConfigManager.getCheckoutURL(self.config, orderType: type) else {
                await self.showConnectionError(ConnectionError(type: .unknown, message: "Unable to build checkout URL"))
                return
            }
            self.loadCheckout(url: url, orderType: type)
        }
    }

    /// Returns nil when the checkout has been terminated instead of resolved.
    ///
    /// The order type is only knowable from a successful fetch; guessing "standard" routes LRS
    /// traffic to the wrong checkout host. The previous catch block resolved to "standard" and
    /// opened the standard checkout, with a comment asserting a Flutter behaviour Flutter does
    /// not have at either tag - it finishes with an error and never navigates the WebView.
    /// A fallback here would be a product decision with the LRS owner, not a catch block.
    private func resolveOrderType() async -> String? {
        if requestedOrderType != "auto" || config.isSubscription || config.orderId == nil {
            let resolved = requestedOrderType == "auto" ? "standard" : requestedOrderType
            flowTypeState.resolve(resolved)
            analytics.updateFlowType(resolved)
            errorReporter.updateFlowType(resolved)
            analytics.track(AnalyticsEventName.orderTypeResolved, properties: ["resolved_type": resolved])
            return resolved
        }

        analytics.track(AnalyticsEventName.orderTypeDetectionStarted)
        do {
            let order = try await apiClient.fetchOrder(config.orderId!)
            let type = ConfigManager.detectOrderType(order)
            flowTypeState.resolve(type)
            analytics.updateFlowType(type)
            errorReporter.updateFlowType(type)
            analytics.track(AnalyticsEventName.orderTypeResolved, properties: ["resolved_type": type])
            return type
        } catch {
            let reason = Self.orderFetchFailureReason(error)
            analytics.track(AnalyticsEventName.orderTypeDetectionFailed, properties: [
                // Reason only. The response body used to travel here as localizedDescription,
                // which shipped an order payload to Mixpanel unredacted.
                "failure_reason": reason,
            ])
            errorReporter.capture(
                operation: "order_type_detection",
                error: error,
                context: ["failure_reason": reason]
            )
            await failCheckoutForOrderFetch(error)
            return nil
        }
    }

    /// Typed, so each cause reports what it actually is: a phone with no signal and a backend
    /// returning 500 must not reach the host through the same callback.
    @MainActor
    private func failCheckoutForOrderFetch(_ error: Error) {
        guard !didTerminate else { return }
        guard let apiError = error as? GlomoPayAPIError else {
            deliverSdkErrors([SdkError(type: .unknown, message: "Unable to determine checkout type.")])
            return
        }
        switch apiError {
        case .requestTimeout:
            deliverOrderConnectionError(ConnectionError(
                type: .timeout,
                message: "Order request timed out.",
                shouldAutoClose: true
            ))
        case .transport:
            deliverOrderConnectionError(ConnectionError(
                type: .noInternet,
                message: "Unable to fetch the order. Please check your connection.",
                shouldAutoClose: true
            ))
        case let .failedToLoadOrder(statusCode):
            // The server answered, so connectivity is fine: this is an SDK/backend fault.
            deliverSdkErrors([SdkError(
                type: .networkError,
                message: "Failed to load order. Status: \(statusCode)"
            )])
        case .invalidOrderResponse, .invalidOrderURL:
            deliverSdkErrors([SdkError(type: .unknown, message: "Malformed order response.")])
        }
    }

    @MainActor
    private func deliverOrderConnectionError(_ error: ConnectionError) {
        loadingView.isHidden = true
        progressView.isHidden = true
        analytics.track(AnalyticsEventName.connectionError, properties: connectionErrorProperties(error))
        errorReporter.capture(
            operation: "order_fetch_connection",
            error: error,
            context: ["error_type": error.type.rawValue]
        )
        deliverToListener { $0.onConnectionError(error) }
        terminate(source: .connectionError)
    }

    /// Never carries the response body, and never a localizedDescription that might.
    private static func orderFetchFailureReason(_ error: Error) -> String {
        guard let apiError = error as? GlomoPayAPIError else { return "unknown" }
        switch apiError {
        case .requestTimeout: return "timeout"
        case let .transport(code): return "transport:\(code)"
        case let .failedToLoadOrder(statusCode): return "http_status:\(statusCode)"
        case .invalidOrderResponse: return "malformed_response"
        case .invalidOrderURL: return "invalid_order_url"
        }
    }

    @MainActor
    private func loadCheckout(url: URL, orderType: String) {
        currentURL = url
        flowTypeState.resolve(orderType)
        analytics.updateFlowType(orderType)
        analytics.updateCheckoutURL(url)
        errorReporter.updateFlowType(orderType)
        analytics.track(AnalyticsEventName.checkoutURLResolved, properties: ["url": url.absoluteString])
        analytics.track(AnalyticsEventName.checkoutStarted)
        advanceOpenStep(.urlResolved)
        startRenderWatchdog()
        webView.load(mainDocumentRequest(for: url))
    }

    private func mainDocumentRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        return request
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === carouselWebView { return }
        if webView === flowWebView {
            flowLoadingView?.isHidden = false
            flowProgressView?.isHidden = false
            analytics.track(AnalyticsEventName.redirectPageStarted, properties: [
                "url": AnalyticsSanitizer.bankRedirectURL(webView.url),
            ])
            return
        }
        loadingView.isHidden = false
        progressView.isHidden = false
        loadingLabel.text = GlomoPayStrings.loadingCheckout
        advanceOpenStep(.navigationStarted)
        analytics.track(AnalyticsEventName.navigationStarted, properties: [
            "url": AnalyticsSanitizer.navigationURL(webView.url),
        ])
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === carouselWebView { return }
        if webView === flowWebView {
            return
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === carouselWebView {
            // Runs only if the page never posted its own availability message.
            webView.evaluateJavaScript(GlomoPayInjectionScripts.carouselFallback(), completionHandler: nil)
            return
        }
        if webView === flowWebView {
            flowLoadingView?.isHidden = true
            flowProgressView?.isHidden = true
            analytics.track(AnalyticsEventName.redirectPageFinished, properties: [
                "url": AnalyticsSanitizer.bankRedirectURL(webView.url),
            ])
            return
        }
        loadingView.isHidden = true
        progressView.isHidden = true
        advanceOpenStep(.navigationFinished)
        analytics.track(AnalyticsEventName.navigationFinished, properties: [
            "url": AnalyticsSanitizer.navigationURL(webView.url),
        ])
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === carouselWebView {
            handleCarouselFailure(error)
            return
        }
        if webView === flowWebView {
            handleFlowError(error, url: webView.url)
            return
        }
        handleWebError(error, url: webView.url)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === carouselWebView {
            handleCarouselFailure(error)
            return
        }
        if webView === flowWebView {
            handleFlowError(error, url: webView.url)
            return
        }
        handleWebError(error, url: webView.url)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if webView === carouselWebView {
            decisionHandler(.allow)
            return
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           !(200..<400).contains(response.statusCode) {
            let isFlow = webView === flowWebView
            analytics.track(AnalyticsEventName.webViewHTTPError, properties: [
                "status_code": response.statusCode,
                "url": isFlow
                    ? AnalyticsSanitizer.bankRedirectURL(response.url)
                    : AnalyticsSanitizer.navigationURL(response.url),
                "webview_type": isFlow ? "flow" : "main",
            ])
            let error = ConnectionError.fromHTTPStatus(response.statusCode, failedURL: response.url)
            if webView === flowWebView {
                showFlowError(error)
            } else {
                deliverConnectionError(error)
            }
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if webView === carouselWebView {
            decisionHandler(FlowNavigationPolicy.allows(navigationAction.request.url) ? .allow : .cancel)
            return
        }
        if webView === flowWebView {
            // The allowlist belongs here and not on the main WebView, which only ever loads
            // GlomoPay's own checkout document. WKWebView never hands an unknown scheme to the
            // system, so a upi:// or intent:// navigation would fail quietly and leave the user
            // on a bank page that appears to have done nothing.
            guard FlowNavigationPolicy.allows(navigationAction.request.url) else {
                let scheme = FlowNavigationPolicy.scheme(of: navigationAction.request.url)
                analytics.track(AnalyticsEventName.nonHTTPNavigationAttempted, properties: [
                    "scheme": scheme,
                    "webview_type": "flow",
                ])
                GlomoPayLogger.log("Blocked non-HTTP bank navigation: \(scheme)")
                decisionHandler(.cancel)
                return
            }
            analytics.track(AnalyticsEventName.redirectURLChange, properties: [
                "url": AnalyticsSanitizer.bankRedirectURL(navigationAction.request.url),
            ])
            decisionHandler(.allow)
            return
        }
        analytics.track(AnalyticsEventName.navigationURLChange, properties: [
            "url": AnalyticsSanitizer.navigationURL(navigationAction.request.url),
        ])
        decisionHandler(.allow)
    }

    private func handleWebError(_ error: Error, url: URL?) {
        let nsError = error as NSError
        // WebKit cancels navigations as a matter of course - a superseded provisional
        // navigation, a client-side redirect during load, stopLoading(). Reporting that as a
        // connection error terminated live checkouts for a non-event.
        if ConnectionError.isCancellation(domain: nsError.domain, errorCode: nsError.code) {
            GlomoPayLogger.log("Ignoring cancelled main navigation")
            return
        }
        if nsError.code == -1017 && !didRetryMainDocument, let retryURL = url ?? currentURL {
            didRetryMainDocument = true
            analytics.track(AnalyticsEventName.iOSDocumentRetry, properties: [
                "url": AnalyticsSanitizer.navigationURL(retryURL),
                "error_code": nsError.code,
            ])
            var request = URLRequest(url: retryURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            webView.load(request)
            return
        }

        let connectionError = ConnectionError.fromWebResourceError(
            description: error.localizedDescription,
            errorCode: nsError.code,
            failedURL: url,
            domain: nsError.domain
        )
        deliverConnectionError(connectionError)
    }

    private func openFlow(_ url: URL) {
        closeFlow()

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .systemBackground
        overlay.layer.zPosition = 100

        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .systemBackground

        let back = UIButton(type: .system)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.setTitle(GlomoPayStrings.back, for: .normal)
        back.addTarget(self, action: #selector(flowBackTapped), for: .touchUpInside)
        toolbar.addSubview(back)

        let flowConfiguration = WKWebViewConfiguration()
        flowConfiguration.websiteDataStore = checkoutDataStore
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.bootstrap(devMode: SDKBuildFlags.internalBuild),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.credentialedRequestsFix,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.iosInputZoomFix,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.iosViewportFitFix,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.flow,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let flowBridge = GlomoPayJavaScriptBridge { [weak self] body in
            DispatchQueue.main.async { self?.eventRouter.handle(body: body) }
        }
        flowBridgeHandler = flowBridge
        userContentController.add(flowBridge, name: "GlomoPayFlowBridge")
        flowConfiguration.userContentController = userContentController

        let flow = WKWebView(frame: .zero, configuration: flowConfiguration)
        flow.translatesAutoresizingMaskIntoConstraints = false
        flow.navigationDelegate = self
        flow.uiDelegate = self
        flow.allowsBackForwardNavigationGestures = false

        let loading = makeFlowLoadingView()
        let progress = UIProgressView(progressViewStyle: .default)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = view.tintColor

        let carouselHost = UIView()
        carouselHost.translatesAutoresizingMaskIntoConstraints = false
        carouselHost.backgroundColor = .systemBackground
        carouselHost.clipsToBounds = true
        carouselHost.isHidden = true
        carouselContainer = carouselHost

        overlay.addSubview(toolbar)
        overlay.addSubview(carouselHost)
        overlay.addSubview(flow)
        overlay.addSubview(loading)
        overlay.addSubview(progress)

        // Flutter's proportions: a 5% back bar plus a 15% carousel strip when the carousel has
        // something to show, and a fixed 48pt bar when it does not. Both variants are built now
        // and swapped in applyCarouselLayout(), so no height is recomputed by hand.
        toolbarFixedConstraint = toolbar.heightAnchor.constraint(
            equalToConstant: CGFloat(EducationCarouselLayout.hidden.barHeight ?? 48)
        )
        toolbarFractionConstraint = toolbar.heightAnchor.constraint(
            equalTo: overlay.heightAnchor,
            multiplier: CGFloat(EducationCarouselLayout.showing.barFraction ?? 0.05)
        )
        carouselZeroConstraint = carouselHost.heightAnchor.constraint(equalToConstant: 0)
        carouselFractionConstraint = carouselHost.heightAnchor.constraint(
            equalTo: overlay.heightAnchor,
            multiplier: CGFloat(EducationCarouselLayout.showing.carouselFraction)
        )

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
            back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            back.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            carouselHost.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            carouselHost.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            carouselHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            flow.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            flow.topAnchor.constraint(equalTo: carouselHost.bottomAnchor),
            flow.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            loading.leadingAnchor.constraint(equalTo: flow.leadingAnchor),
            loading.trailingAnchor.constraint(equalTo: flow.trailingAnchor),
            loading.topAnchor.constraint(equalTo: flow.topAnchor),
            loading.bottomAnchor.constraint(equalTo: flow.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            progress.topAnchor.constraint(equalTo: flow.topAnchor),
        ])

        flowWebView = flow
        flowOverlay = overlay
        flowLoadingView = loading
        flowProgressView = progress
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        carouselState = .pending
        applyCarouselLayout()
        prepareCarouselIfNeeded(host: carouselHost)
        flow.load(URLRequest(url: url))
    }

    // MARK: - LRS education carousel

    private var isLRSCheckout: Bool {
        flowTypeState.currentOrderType.lowercased() == "lrs" && !config.isSubscription
    }

    /// Loads the hosted carousel above the bank page for LRS orders.
    ///
    /// The strip stays hidden until the page says it has content, so a non-LRS order and an LRS
    /// order with nothing to teach both render the bank page at full height.
    private func prepareCarouselIfNeeded(host: UIView) {
        guard isLRSCheckout, let url = ConfigManager.getCarouselURL(config) else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = checkoutDataStore
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.carousel(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let bridge = GlomoPayJavaScriptBridge { [weak self] body in
            DispatchQueue.main.async { self?.handleCarouselMessage(body) }
        }
        carouselBridgeHandler = bridge
        controller.add(bridge, name: "GlomoCarouselBridge")
        configuration.userContentController = controller

        let carousel = WKWebView(frame: .zero, configuration: configuration)
        carousel.translatesAutoresizingMaskIntoConstraints = false
        carousel.navigationDelegate = self
        carousel.allowsBackForwardNavigationGestures = false
        carousel.scrollView.isScrollEnabled = false
        carousel.isOpaque = false
        carouselWebView = carousel

        host.addSubview(carousel)
        NSLayoutConstraint.activate([
            carousel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            carousel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            carousel.topAnchor.constraint(equalTo: host.topAnchor),
            carousel.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        carousel.load(URLRequest(url: url))
    }

    private func handleCarouselMessage(_ body: Any) {
        let signal: Bool?
        if let text = body as? String {
            signal = EducationCarouselContract.parseAvailabilitySignal(rawMessage: text)
        } else if let dictionary = body as? [String: Any] {
            signal = EducationCarouselContract.availabilitySignal(dictionary)
        } else {
            signal = nil
        }
        guard let signal else { return }
        setCarouselState(signal ? .hasContent : .noContent)
    }

    private func handleCarouselFailure(_ error: Error) {
        let nsError = error as NSError
        guard !ConnectionError.isCancellation(domain: nsError.domain, errorCode: nsError.code) else { return }
        analytics.track(AnalyticsEventName.educationStepsFailed, properties: ["reason": "webview_error"])
        setCarouselState(.noContent)
    }

    private func setCarouselState(_ state: EducationCarouselState) {
        guard carouselState != state else { return }
        carouselState = state
        if state == .hasContent {
            analytics.track(AnalyticsEventName.educationStepsShown, properties: ["source": "carousel"])
        }
        applyCarouselLayout()
    }

    private func applyCarouselLayout() {
        let layout = EducationCarouselContract.layout(
            state: carouselState,
            isLRSOrder: isLRSCheckout,
            isSubscription: config.isSubscription
        )
        carouselContainer?.isHidden = !layout.showsCarousel
        toolbarFractionConstraint?.isActive = false
        toolbarFixedConstraint?.isActive = false
        carouselFractionConstraint?.isActive = false
        carouselZeroConstraint?.isActive = false
        if layout.showsCarousel {
            toolbarFractionConstraint?.isActive = true
            carouselFractionConstraint?.isActive = true
        } else {
            toolbarFixedConstraint?.isActive = true
            carouselZeroConstraint?.isActive = true
        }
        flowOverlay?.setNeedsLayout()
    }

    private func destroyCarousel() {
        carouselWebView?.navigationDelegate = nil
        carouselWebView?.stopLoading()
        carouselWebView?.configuration.userContentController.removeAllUserScripts()
        carouselWebView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "GlomoCarouselBridge")
        carouselWebView?.removeFromSuperview()
        carouselWebView = nil
        carouselBridgeHandler = nil
        carouselContainer = nil
        carouselState = .pending
        carouselFractionConstraint = nil
        carouselZeroConstraint = nil
        toolbarFractionConstraint = nil
        toolbarFixedConstraint = nil
    }

    // Deliberately no `runOpenPanelWith` implementation.
    //
    // That delegate method is @available(iOS 18.4, *), and WKUIDelegate's contract is that when
    // it is not implemented "the web view will match the file upload behavior of Safari". So
    // implementing it produced two different upload experiences across the live fleet: on
    // 15.0-18.3 WebKit's own sheet offered Camera, Photo Library and Files, while on 18.4+ the
    // SDK replaced that sheet with a UIDocumentPickerViewController - removing capture options
    // the platform provided for free, on a KYC field where photographing a document is the
    // common case. WebKit's sheet is closer to the intended behaviour than a document picker is,
    // and it is the same on every supported OS.
    //
    // The cost of this position, recorded so it is not rediscovered as a bug: no picker
    // telemetry (the `file.input` bridge event still reports File Upload Requested from the
    // page's own click, which is where the accept types come from) and no control over
    // accept-type behaviour - which v2.0.0 asks for anyway, since `accept` selects which picker
    // opens and never restricts what may be chosen. Revisit only as the full picker: an action
    // sheet with camera / photo library / files, PHPickerViewController, the camera permission
    // and refusal callback, and the capture caps that keep uploads under the bank's limit.

    private func closeFlow() {
        let hadFlow = flowWebView != nil || flowOverlay != nil
        // Delegate first, then stop: stopLoading() delivers NSURLErrorCancelled, and clearing
        // the delegate afterwards let that cancellation arrive against an overlay already being
        // torn down.
        flowWebView?.navigationDelegate = nil
        flowWebView?.uiDelegate = nil
        flowWebView?.stopLoading()
        destroyCarousel()
        flowWebView?.configuration.userContentController.removeAllUserScripts()
        flowWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "GlomoPayFlowBridge")
        flowWebView?.removeFromSuperview()
        flowOverlay?.removeFromSuperview()
        flowWebView = nil
        flowBridgeHandler = nil
        flowOverlay = nil
        flowLoadingView = nil
        flowProgressView = nil
        flowErrorView?.removeFromSuperview()
        flowErrorView = nil
        if hadFlow {
            analytics.track(AnalyticsEventName.redirectClosed, properties: ["source": "flow"])
        }
    }

    private func handleFlowError(_ error: Error, url: URL?) {
        let nsError = error as NSError
        if ConnectionError.isCancellation(domain: nsError.domain, errorCode: nsError.code) {
            GlomoPayLogger.log("Ignoring cancelled bank-flow navigation")
            return
        }
        let connectionError = ConnectionError.fromWebResourceError(
            description: error.localizedDescription,
            errorCode: nsError.code,
            failedURL: url,
            domain: nsError.domain
        )
        showFlowError(connectionError)
        analytics.track(AnalyticsEventName.connectionError, properties: connectionErrorProperties(connectionError))
        errorReporter.capture(
            operation: "flow_webview_connection",
            error: connectionError,
            context: ["error_type": connectionError.type.rawValue, "error_code": nsError.code]
        )
    }

    private func showFlowError(_ error: ConnectionError) {
        flowLoadingView?.isHidden = true
        flowProgressView?.isHidden = true
        guard let overlay = flowOverlay, let flow = flowWebView else { return }
        flowErrorView?.removeFromSuperview()
        let panel = makeErrorPanel(
            message: GlomoPayStrings.connectionErrorMessage,
            retry: #selector(flowRetryTapped),
            cancel: #selector(flowBackTapped)
        )
        overlay.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: flow.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: flow.trailingAnchor),
            panel.topAnchor.constraint(equalTo: flow.topAnchor),
            panel.bottomAnchor.constraint(equalTo: flow.bottomAnchor),
        ])
        flowErrorView = panel
    }

    @objc private func flowRetryTapped() {
        flowErrorView?.removeFromSuperview()
        flowErrorView = nil
        flowLoadingView?.isHidden = false
        flowProgressView?.isHidden = false
        flowWebView?.reload()
    }

    private func makeFlowLoadingView() -> UIView {
        let loading = UIView()
        loading.translatesAutoresizingMaskIntoConstraints = false
        loading.backgroundColor = .systemBackground
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = GlomoPayStrings.openingSecurePage
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        loading.addSubview(indicator)
        loading.addSubview(label)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: loading.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: loading.centerYAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: loading.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: loading.trailingAnchor, constant: -24),
        ])
        return loading
    }

    /// Closes the overlay, unconditionally.
    ///
    /// This control returns the user to checkout; it does not walk the bank page's own history.
    /// History-walking here makes the exit unreachable, because bank redirect chains leave
    /// history that never drains - `canGoBack` is true from the second hop onward, so the close
    /// path became unreachable and the user was welded inside the overlay. Flutter removed this
    /// twice; there is one control on the overlay and it always means close.
    @objc private func flowBackTapped() {
        guard flowWebView != nil else { return }
        closeFlow()
    }

    private func handleResult(_ result: GlomoPayResult) {
        didTerminate = true
        cancelOpenWatchdogs()
        closeFlow()
        switch result {
        case .success, .failure, .userJourney, .cancelled:
            flushTerminalErrorReports()
            dismiss(animated: true)
        }
    }

    private func showConnectionError(_ error: ConnectionError) async {
        await MainActor.run { self.deliverConnectionError(error) }
    }

    private func deliverConnectionError(_ error: ConnectionError) {
        guard !didTerminate else { return }
        loadingView.isHidden = true
        progressView.isHidden = true
        analytics.track(AnalyticsEventName.connectionError, properties: connectionErrorProperties(error))
        errorReporter.capture(
            operation: "webview_connection",
            error: error,
            context: ["error_type": error.type.rawValue, "status_code": error.statusCode]
        )
        deliverToListener { $0.onConnectionError(error) }
        showErrorView(error)
        if config.autoCloseOnConnectionError && error.shouldAutoClose {
            terminate(source: .connectionError)
        }
    }

    private func showErrorView(_ error: ConnectionError) {
        errorView?.removeFromSuperview()
        let panel = makeErrorPanel(
            message: error.message,
            retry: #selector(retryTapped),
            cancel: #selector(closeTapped)
        )
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        errorView = panel
    }

    /// One surface for both WebViews: a title, the message, and both a retry and a way out.
    ///
    /// The flow overlay used to reach into the loading view's subviews by type to find a label,
    /// write an untranslated `NSError.localizedDescription` into it, and offer no control at all.
    private func makeErrorPanel(message: String, retry: Selector, cancel: Selector) -> UIView {
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = GlomoPayStrings.connectionErrorTitle
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        let body = UILabel()
        // The mapped message, not a raw NSError description: those are untranslated and often
        // meaningless to a paying user.
        body.text = message
        body.numberOfLines = 0
        body.textAlignment = .center
        body.textColor = .secondaryLabel
        body.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(body)

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 24
        actions.alignment = .center
        actions.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(actions)

        let retryButton = UIButton(type: .system)
        retryButton.setTitle(GlomoPayStrings.retry, for: .normal)
        retryButton.addTarget(self, action: retry, for: .touchUpInside)
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle(GlomoPayStrings.cancel, for: .normal)
        cancelButton.addTarget(self, action: cancel, for: .touchUpInside)
        actions.addArrangedSubview(retryButton)
        actions.addArrangedSubview(cancelButton)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: -70),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            actions.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 24),
            actions.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
        ])
        return panel
    }

    @objc private func retryTapped() {
        errorView?.removeFromSuperview()
        errorView = nil
        didRetryMainDocument = false
        didRetryAfterProcessTermination = false
        // A retry is a new open attempt: it gets its own funnel and its own timeout budget,
        // otherwise the second attempt could never report a timeout of its own.
        openFunnel = CheckoutOpenFunnel()
        startOpenWatchdog()
        currentURL.map { loadCheckout(url: $0, orderType: orderTypeForCurrentCheckoutLoad()) }
    }

    func orderTypeForCurrentCheckoutLoad() -> String {
        flowTypeState.currentOrderType
    }

    @objc private func closeTapped() {
        terminate(source: .userDismiss)
    }

    /// Dismisses this checkout from host code. Safe to call more than once; after the checkout
    /// has already finished it does nothing.
    public func closeCheckout() {
        terminate(source: .programmatic)
    }

    /// Every host callback goes through here, on the main queue, and a dropped listener is
    /// reported instead of disappearing.
    ///
    /// `listener` is weak on purpose - the SDK does not keep a merchant object alive - but that
    /// means a host passing something it does not otherwise retain (a coordinator, a short-lived
    /// handler) could run a checkout to completion and be told nothing at all. That is now
    /// visible in analytics and Sentry. The retention contract is documented at
    /// `GlomoPaySDK.startCheckout` and in the README.
    @discardableResult
    private func deliverToListener(_ deliver: (GlomoPayListener) -> Void) -> Bool {
        guard let listener else {
            analytics.track(AnalyticsEventName.listenerUnavailable)
            errorReporter.capture(
                operation: "listener_unavailable",
                error: CheckoutMonitoringError.listenerReleased,
                context: ["session_id": sessionID]
            )
            return false
        }
        deliver(listener)
        return true
    }

    private func terminate(source: TerminationSource) {
        guard !didTerminate else { return }
        didTerminate = true
        cancelOpenWatchdogs()
        analytics.track(AnalyticsEventName.paymentTerminated, properties: [
            "termination_source": analyticsTerminationSource(source),
        ])
        deliverToListener { $0.onPaymentTerminate(source) }
        flushTerminalErrorReports()
        dismiss(animated: true)
    }

    private func deliverSdkErrors(_ errors: [SdkError]) {
        didTerminate = true
        analytics.track(AnalyticsEventName.sdkError, properties: [
            "error_count": errors.count,
            "errors": SDKErrorAnalyticsSerializer.serialize(errors),
        ])
        if let first = errors.first {
            errorReporter.capture(operation: "sdk_error", error: first, context: ["error_type": first.type.rawValue])
        }
        deliverToListener { $0.onSdkError(errors) }
        flushTerminalErrorReports()
        dismiss(animated: true)
    }

    private func flushTerminalErrorReports() {
        SDKErrorReporterTerminalFlusher.flush(errorReporter)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === carouselWebView {
            // The carousel is decoration: losing it must not touch the payment WebViews.
            analytics.track(AnalyticsEventName.educationStepsFailed, properties: [
                "reason": "content_process_terminated",
            ])
            setCarouselState(.noContent)
            destroyCarousel()
            return
        }
        let isFlow = webView === flowWebView
        analytics.track(AnalyticsEventName.webViewError, properties: [
            "error_type": "content_process_terminated",
            "error_message": "WKWebView content process terminated",
            "webview_type": isFlow ? "flow" : "main",
        ])
        errorReporter.capture(
            operation: "webview_process",
            error: CheckoutMonitoringError.webContentProcessTerminated,
            context: ["webview_type": isFlow ? "flow" : "main"]
        )

        switch WebContentProcessRecovery.action(
            isFlow: isFlow,
            didRetryMain: didRetryAfterProcessTermination,
            hasCurrentURL: currentURL != nil
        ) {
        case .closeFlow:
            closeFlow()
        case .reloadMain:
            guard let currentURL else { return }
            didRetryAfterProcessTermination = true
            let flowType = orderTypeForCurrentCheckoutLoad()
            analytics.updateFlowType(flowType)
            errorReporter.updateFlowType(flowType)
            loadingView.isHidden = false
            progressView.isHidden = false
            loadingLabel.text = GlomoPayStrings.recoveringCheckout
            webView.load(mainDocumentRequest(for: currentURL))
        case .reportMainFailure:
            deliverConnectionError(ConnectionError(
                type: .unknown,
                message: "The checkout WebView stopped unexpectedly.",
                failedURL: currentURL
            ))
        }
    }

    private func connectionErrorProperties(_ error: ConnectionError) -> [String: Any?] {
        [
            "error_code": error.errorCode,
            "error_description": error.message,
            "url": AnalyticsSanitizer.navigationURL(error.failedURL),
            "is_recoverable": error.isRecoverable,
        ]
    }

    private func validationFailureReason(_ error: SdkError?) -> String {
        switch error?.field {
        case "publicKey": return "invalid_public_key"
        case "orderId": return "missing_order_id"
        case "subscriptionId": return "invalid_subscription_id"
        case "identifier": return "missing_order_id"
        case "server": return "invalid_checkout_url"
        default: return "validation_error"
        }
    }

    private func analyticsTerminationSource(_ source: TerminationSource) -> String {
        switch source {
        case .userDismiss: return "user_dismiss"
        case .programmatic: return "checkout_closed"
        case .connectionError: return "checkout_closed"
        }
    }
}

private enum CheckoutMonitoringError: Error {
    case webContentProcessTerminated
    case listenerReleased
}
#endif
