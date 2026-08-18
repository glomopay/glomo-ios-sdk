#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import UniformTypeIdentifiers

/// Native iOS host for the main GlomoPay checkout document.
///
/// The JavaScript message bridge is deliberately attached in the next phase;
/// this controller owns only presentation, navigation, loading, and network
/// error behavior so those concerns stay independently testable.
public final class GlomoPayCheckoutViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    public let config: GlomoPayConfig
    public let requestedOrderType: String
    public weak var listener: GlomoPayListener?
    public var autoCloseOnConnectionError = true

    private let apiClient: GlomoPayApiClient
    private let sessionID: String
    private let analytics: AnalyticsTracking
    private let errorReporter: SDKErrorReporting
    private var webView: WKWebView!
    private var flowWebView: WKWebView?
    private var flowOverlay: UIView?
    private var flowLoadingView: UIView?
    private var flowProgressView: UIProgressView?
    private var progressView: UIProgressView!
    private var loadingView: UIView!
    private var loadingLabel: UILabel!
    private var errorView: UIView?
    private var currentURL: URL?
    private var didRetryMainDocument = false
    private var didTerminate = false
    private var progressObservation: NSKeyValueObservation?
    private var bridgeHandler: GlomoPayJavaScriptBridge?
    private var flowBridgeHandler: GlomoPayJavaScriptBridge?
    private var filePickerCompletion: (([URL]?) -> Void)?
    private var eventRouter: GlomoPayEventRouter!

    public init(
        config: GlomoPayConfig,
        orderType: String = "auto",
        listener: GlomoPayListener? = nil,
        apiClient: GlomoPayApiClient? = nil
    ) {
        let normalizedOrderType = orderType.lowercased()
        let sessionID = UUID().uuidString.lowercased()
        let errorReporter = SDKErrorReporterFactory.create(
            config: config,
            sessionID: sessionID,
            flowType: normalizedOrderType
        )
        self.config = config
        self.requestedOrderType = normalizedOrderType
        self.listener = listener
        self.apiClient = apiClient ?? GlomoPayApiClient(publicKey: config.publicKey, devMode: config.devMode)
        self.sessionID = sessionID
        self.errorReporter = errorReporter
        self.analytics = AnalyticsFactory.create(
            config: config,
            sessionID: sessionID,
            flowType: normalizedOrderType,
            errorReporter: errorReporter
        )
        GlomoPayLogger.devMode = config.devMode
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
        view.backgroundColor = .systemBackground
        eventRouter = GlomoPayEventRouter(
            listener: listener,
            devMode: config.devMode,
            onComplete: { [weak self] result in self?.handleResult(result) },
            onWindowOpen: { [weak self] url in self?.openFlow(url) },
            onWindowClose: { [weak self] in self?.closeFlow() },
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
    }

    private func configureWebView() {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .default()
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.bootstrap(devMode: config.devMode),
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
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
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
        loadingLabel.text = "Loading checkout..."
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
        navigationItem.title = "Checkout"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
    }

    private func startCheckout() {
        analytics.track(AnalyticsEventName.sdkInitialized)
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
            properties: complianceAnalyticsProperties(compliance)
        )
        listener?.onEvent(name: "device.compliance_checked", payload: [
            "isCompliant": compliance.isCompliant,
            "isSimulator": compliance.isSimulator,
            "checksSkipped": compliance.checksSkipped,
        ])
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
            let type = await self.resolveOrderType()
            guard !self.didTerminate else { return }
            guard let url = ConfigManager.getCheckoutURL(self.config, orderType: type) else {
                await self.showConnectionError(ConnectionError(type: .unknown, message: "Unable to build checkout URL"))
                return
            }
            self.loadCheckout(url: url, orderType: type)
        }
    }

    private func resolveOrderType() async -> String {
        if requestedOrderType != "auto" || config.isSubscription || config.orderId == nil {
            let resolved = requestedOrderType == "auto" ? "standard" : requestedOrderType
            analytics.updateFlowType(resolved)
            errorReporter.updateFlowType(resolved)
            analytics.track(AnalyticsEventName.orderTypeResolved, properties: ["resolved_type": resolved])
            return resolved
        }

        analytics.track(AnalyticsEventName.orderTypeDetectionStarted)
        do {
            let order = try await apiClient.fetchOrder(config.orderId!)
            let type = ConfigManager.detectOrderType(order)
            analytics.updateFlowType(type)
            errorReporter.updateFlowType(type)
            analytics.track(AnalyticsEventName.orderTypeResolved, properties: ["resolved_type": type])
            listener?.onEvent(name: "checkout.order_type_detected", payload: ["orderType": type])
            return type
        } catch {
            // Flutter continues with standard checkout if order detection fails.
            analytics.updateFlowType("standard")
            errorReporter.updateFlowType("standard")
            analytics.track(AnalyticsEventName.orderTypeDetectionFailed, properties: [
                "error": error.localizedDescription,
                "fallback_type": "standard",
            ])
            listener?.onEvent(name: "checkout.order_detection_failed", payload: ["message": error.localizedDescription])
            return "standard"
        }
    }

    @MainActor
    private func loadCheckout(url: URL, orderType: String) {
        currentURL = url
        analytics.updateFlowType(orderType)
        analytics.updateCheckoutURL(url)
        errorReporter.updateFlowType(orderType)
        analytics.track(AnalyticsEventName.checkoutURLResolved, properties: ["url": url.absoluteString])
        analytics.track(AnalyticsEventName.checkoutStarted)
        listener?.onEvent(name: "checkout.url_resolved", payload: ["url": url.absoluteString, "orderType": orderType])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        webView.load(request)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === flowWebView {
            flowLoadingView?.isHidden = false
            flowProgressView?.isHidden = false
            analytics.track(AnalyticsEventName.redirectPageStarted, properties: [
                "url": AnalyticsSanitizer.bankRedirectURL(webView.url),
            ])
            listener?.onEvent(name: "flow.page_started", payload: ["url": webView.url?.absoluteString ?? ""])
            return
        }
        loadingView.isHidden = false
        progressView.isHidden = false
        loadingLabel.text = "Loading checkout..."
        analytics.track(AnalyticsEventName.navigationStarted, properties: [
            "url": AnalyticsSanitizer.navigationURL(webView.url),
        ])
        listener?.onEvent(name: "navigation.started", payload: ["url": webView.url?.absoluteString ?? ""])
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === flowWebView {
            listener?.onEvent(name: "flow.page_committed", payload: ["url": webView.url?.absoluteString ?? ""])
            return
        }
        listener?.onEvent(name: "navigation.committed", payload: ["url": webView.url?.absoluteString ?? ""])
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === flowWebView {
            flowLoadingView?.isHidden = true
            flowProgressView?.isHidden = true
            analytics.track(AnalyticsEventName.redirectPageFinished, properties: [
                "url": AnalyticsSanitizer.bankRedirectURL(webView.url),
            ])
            listener?.onEvent(name: "flow.page_finished", payload: ["url": webView.url?.absoluteString ?? ""])
            return
        }
        loadingView.isHidden = true
        progressView.isHidden = true
        analytics.track(AnalyticsEventName.navigationFinished, properties: [
            "url": AnalyticsSanitizer.navigationURL(webView.url),
        ])
        listener?.onEvent(name: "navigation.finished", payload: ["url": webView.url?.absoluteString ?? ""])
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === flowWebView {
            handleFlowError(error, url: webView.url)
            return
        }
        handleWebError(error, url: webView.url)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
            if navigationResponse.response.url == flowWebView?.url {
                listener?.onEvent(name: "flow.http_error", payload: [
                    "url": response.url?.absoluteString ?? "",
                    "statusCode": response.statusCode,
                ])
            }
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
        if webView === flowWebView {
            analytics.track(AnalyticsEventName.redirectURLChange, properties: [
                "url": AnalyticsSanitizer.bankRedirectURL(navigationAction.request.url),
            ])
            listener?.onEvent(name: "flow.url_change", payload: ["url": navigationAction.request.url?.absoluteString ?? ""])
            decisionHandler(.allow)
            return
        }
        analytics.track(AnalyticsEventName.navigationURLChange, properties: [
            "url": AnalyticsSanitizer.navigationURL(navigationAction.request.url),
        ])
        listener?.onEvent(name: "navigation.url_change", payload: ["url": navigationAction.request.url?.absoluteString ?? ""])
        decisionHandler(.allow)
    }

    private func handleWebError(_ error: Error, url: URL?) {
        let nsError = error as NSError
        if nsError.code == -1017 && !didRetryMainDocument, let retryURL = url ?? currentURL {
            didRetryMainDocument = true
            analytics.track(AnalyticsEventName.iOSDocumentRetry, properties: [
                "url": AnalyticsSanitizer.navigationURL(retryURL),
                "error_code": nsError.code,
            ])
            listener?.onEvent(name: "ios.main_document_retry", payload: [
                "errorCode": nsError.code,
                "failedUrl": url?.absoluteString ?? "",
                "retryUrl": retryURL.absoluteString,
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
            failedURL: url
        )
        deliverConnectionError(connectionError)
    }

    private func openFlow(_ url: URL) {
        closeFlow()
        listener?.onEvent(name: "redirect.opened", payload: ["url": url.absoluteString])

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .systemBackground
        overlay.layer.zPosition = 100

        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .systemBackground

        let back = UIButton(type: .system)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.setTitle("Back", for: .normal)
        back.addTarget(self, action: #selector(flowBackTapped), for: .touchUpInside)
        toolbar.addSubview(back)

        let flowConfiguration = WKWebViewConfiguration()
        flowConfiguration.websiteDataStore = .default()
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.bootstrap(devMode: config.devMode),
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
        flow.allowsBackForwardNavigationGestures = true

        let loading = makeFlowLoadingView()
        let progress = UIProgressView(progressViewStyle: .default)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = view.tintColor

        overlay.addSubview(toolbar)
        overlay.addSubview(flow)
        overlay.addSubview(loading)
        overlay.addSubview(progress)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 50),
            back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            back.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            flow.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            flow.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
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
        flow.load(URLRequest(url: url))
    }

    @available(iOS 18.4, *)
    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        filePickerCompletion?([])
        filePickerCompletion = completionHandler

        guard presentedViewController == nil else {
            analytics.track(AnalyticsEventName.filePickerError, properties: [
                "accept_types": "",
                "error_message": "Another view controller is already presented",
                "picker_method": "document_picker",
            ])
            filePickerCompletion?([])
            filePickerCompletion = nil
            return
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.item],
            asCopy: true
        )
        picker.allowsMultipleSelection = parameters.allowsMultipleSelection
        picker.delegate = self
        present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        filePickerCompletion?(urls)
        filePickerCompletion = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        filePickerCompletion?([])
        filePickerCompletion = nil
    }

    private func closeFlow() {
        let hadFlow = flowWebView != nil || flowOverlay != nil
        flowWebView?.stopLoading()
        flowWebView?.navigationDelegate = nil
        flowWebView?.configuration.userContentController.removeAllUserScripts()
        flowWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "GlomoPayFlowBridge")
        flowWebView?.removeFromSuperview()
        flowOverlay?.removeFromSuperview()
        flowWebView = nil
        flowBridgeHandler = nil
        flowOverlay = nil
        flowLoadingView = nil
        flowProgressView = nil
        if hadFlow {
            analytics.track(AnalyticsEventName.redirectClosed, properties: ["source": "flow"])
            listener?.onEvent(name: "redirect.closed", payload: [:])
        }
    }

    private func handleFlowError(_ error: Error, url: URL?) {
        let nsError = error as NSError
        let connectionError = ConnectionError.fromWebResourceError(
            description: error.localizedDescription,
            errorCode: nsError.code,
            failedURL: url
        )
        showFlowError(connectionError)
        analytics.track(AnalyticsEventName.connectionError, properties: connectionErrorProperties(connectionError))
        listener?.onEvent(name: "flow.error", payload: [
            "type": connectionError.type.rawValue,
            "message": connectionError.message,
            "errorCode": nsError.code,
            "failedUrl": url?.absoluteString ?? "",
        ])
    }

    private func showFlowError(_ error: ConnectionError) {
        flowLoadingView?.isHidden = false
        flowLoadingView?.subviews.compactMap { $0 as? UILabel }.first?.text = error.message
        flowProgressView?.isHidden = true
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
        label.text = "Opening secure page..."
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

    @objc private func flowBackTapped() {
        guard let flow = flowWebView else { return }
        if flow.canGoBack {
            flow.goBack()
        } else {
            closeFlow()
        }
    }

    private func handleResult(_ result: GlomoPayResult) {
        didTerminate = true
        closeFlow()
        switch result {
        case .success, .failure, .cancelled:
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
        listener?.onConnectionError(error)
        listener?.onEvent(name: "connection.error", payload: [
            "type": error.type.rawValue,
            "message": error.message,
            "statusCode": error.statusCode as Any,
            "failedUrl": error.failedURL?.absoluteString as Any,
        ])
        showErrorView(error)
        if autoCloseOnConnectionError && error.shouldAutoClose {
            terminate(source: .connectionError)
        }
    }

    private func showErrorView(_ error: ConnectionError) {
        errorView?.removeFromSuperview()
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = .systemBackground
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let title = UILabel()
        title.text = "Connection Error"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        let message = UILabel()
        message.text = error.message
        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = .secondaryLabel
        message.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(message)

        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retry.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(retry)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: -70),
            message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            message.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            message.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            retry.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 24),
            retry.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
        ])
        errorView = panel
    }

    @objc private func retryTapped() {
        errorView?.removeFromSuperview()
        errorView = nil
        didRetryMainDocument = false
        currentURL.map { loadCheckout(url: $0, orderType: requestedOrderType) }
    }

    @objc private func closeTapped() {
        terminate(source: .userDismiss)
    }

    private func terminate(source: TerminationSource) {
        guard !didTerminate else { return }
        didTerminate = true
        analytics.track(AnalyticsEventName.paymentTerminated, properties: [
            "termination_source": analyticsTerminationSource(source),
        ])
        listener?.onPaymentTerminate(source)
        listener?.onEvent(name: "checkout.closed", payload: ["source": source.rawValue])
        dismiss(animated: true)
    }

    private func deliverSdkErrors(_ errors: [SdkError]) {
        didTerminate = true
        let serialized = errors.map {
            ["type": $0.type.rawValue, "message": AnalyticsSanitizer.text($0.message, limit: 500), "field": $0.field as Any]
        }
        let data = try? JSONSerialization.data(withJSONObject: serialized)
        analytics.track(AnalyticsEventName.sdkError, properties: [
            "error_count": errors.count,
            "errors": data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
        ])
        if let first = errors.first {
            errorReporter.capture(operation: "sdk_error", error: first, context: ["error_type": first.type.rawValue])
        }
        listener?.onSdkError(errors)
        dismiss(animated: true)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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
    }

    private func complianceAnalyticsProperties(_ result: DeviceComplianceResult) -> [String: Any?] {
        let skipped = config.devMode || result.checksSkipped
        return [
            "is_compliant": skipped ? nil : result.isCompliant,
            "is_jailbroken": skipped ? nil : result.isJailbroken,
            "is_emulator": skipped ? nil : result.isSimulator,
            "is_developer_mode_enabled": skipped ? nil : result.isDeveloperModeEnabled,
            "is_debugger_attached": skipped ? nil : result.isDebuggerAttached,
            "is_usb_debugging_enabled": nil,
            "has_test_keys": nil,
        ]
    }

    private func connectionErrorProperties(_ error: ConnectionError) -> [String: Any?] {
        [
            "error_code": error.errorCode.map(String.init),
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
        case .backButton: return "back_button"
        case .userDismiss: return "user_dismiss"
        case .programmatic: return "checkout_closed"
        case .connectionError: return "checkout_closed"
        }
    }
}

private enum CheckoutMonitoringError: Error {
    case webContentProcessTerminated
}
#endif
