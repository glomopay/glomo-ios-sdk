#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// Native iOS host for the main GlomoPay checkout document.
///
/// The JavaScript message bridge is deliberately attached in the next phase;
/// this controller owns only presentation, navigation, loading, and network
/// error behavior so those concerns stay independently testable.
public final class GlomoPayCheckoutViewController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    public let config: GlomoPayConfig
    public let requestedOrderType: String
    public weak var listener: GlomoPayListener?
    public var autoCloseOnConnectionError = true

    private let apiClient: GlomoPayApiClient
    private let analytics: GlomoPayAnalytics
    private var webView: WKWebView!
    private var progressView: UIProgressView!
    private var loadingView: UIView!
    private var loadingLabel: UILabel!
    private var errorView: UIView?
    private var currentURL: URL?
    private var didRetryMainDocument = false
    private var didTerminate = false
    private var progressObservation: NSKeyValueObservation?
    private var bridgeHandler: GlomoPayJavaScriptBridge?
    private var eventRouter: GlomoPayEventRouter!

    public init(
        config: GlomoPayConfig,
        orderType: String = "auto",
        listener: GlomoPayListener? = nil,
        apiClient: GlomoPayApiClient? = nil
    ) {
        self.config = config
        self.requestedOrderType = orderType.lowercased()
        self.listener = listener
        self.apiClient = apiClient ?? GlomoPayApiClient(publicKey: config.publicKey, devMode: config.devMode)
        self.analytics = GlomoPayAnalytics(devMode: config.devMode)
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
        analytics.setCheckoutContext(
            orderID: config.checkoutId,
            publicKey: config.publicKey,
            mockMode: ConfigManager.isTestOrMock(config.publicKey)
        )
        analytics.trackEvent("GlomoPay Checkout Session Started")
        analytics.trackStartAttempt()
        eventRouter = GlomoPayEventRouter(
            listener: listener,
            devMode: config.devMode,
            onComplete: { [weak self] result in self?.handleResult(result) },
            onWindowOpen: { [weak self] url in self?.openFlow(url) },
            onWindowClose: { [weak self] in self?.closeFlow() },
            onAnalyticsEvent: { [weak self] name, properties in
                self?.analytics.trackEvent(name, additionalProperties: properties)
            }
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
        let errors = Validator.validate(config: config)
        guard errors.isEmpty else {
            analytics.trackStartFailure(reason: errors.first?.message, errorCode: errors.first?.type.rawValue)
            deliverSdkErrors(errors)
            return
        }

        let compliance = DeviceComplianceChecker().check(
            strict: CompliancePolicy.requiresStrictCheck(config)
        )
        listener?.onEvent(name: "device.compliance_checked", payload: [
            "isCompliant": compliance.isCompliant,
            "isSimulator": compliance.isSimulator,
            "checksSkipped": compliance.checksSkipped,
        ])
        analytics.setCheckoutContext(isJailbroken: compliance.isJailbroken)
        guard compliance.isCompliant else {
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
            await self.loadCheckout(url: url, orderType: type)
        }
    }

    private func resolveOrderType() async -> String {
        if requestedOrderType != "auto" || config.isSubscription || config.orderId == nil {
            return requestedOrderType == "auto" ? "standard" : requestedOrderType
        }

        do {
            let order = try await apiClient.fetchOrder(config.orderId!)
            let type = ConfigManager.detectOrderType(order)
            listener?.onEvent(name: "checkout.order_type_detected", payload: ["orderType": type])
            return type
        } catch {
            // Flutter continues with standard checkout if order detection fails.
            listener?.onEvent(name: "checkout.order_detection_failed", payload: ["message": error.localizedDescription])
            return "standard"
        }
    }

    @MainActor
    private func loadCheckout(url: URL, orderType: String) {
        currentURL = url
        analytics.setCheckoutContext(checkoutURL: url.absoluteString, checkoutType: orderType)
        analytics.trackStartSuccess()
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
        loadingView.isHidden = false
        progressView.isHidden = false
        loadingLabel.text = "Loading checkout..."
        listener?.onEvent(name: "navigation.started", payload: ["url": webView.url?.absoluteString ?? ""])
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        listener?.onEvent(name: "navigation.committed", payload: ["url": webView.url?.absoluteString ?? ""])
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingView.isHidden = true
        progressView.isHidden = true
        listener?.onEvent(name: "navigation.finished", payload: ["url": webView.url?.absoluteString ?? ""])
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebError(error, url: webView.url)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWebError(error, url: webView.url)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse,
           !(200..<400).contains(response.statusCode) {
            let error = ConnectionError.fromHTTPStatus(response.statusCode, failedURL: response.url)
            deliverConnectionError(error)
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        listener?.onEvent(name: "navigation.url_change", payload: ["url": navigationAction.request.url?.absoluteString ?? ""])
        decisionHandler(.allow)
    }

    private func handleWebError(_ error: Error, url: URL?) {
        let nsError = error as NSError
        if nsError.code == -1017 && !didRetryMainDocument, let retryURL = url ?? currentURL {
            didRetryMainDocument = true
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
        listener?.onEvent(name: "redirect.opened", payload: ["url": url.absoluteString])
        webView.load(URLRequest(url: url))
    }

    private func closeFlow() {
        listener?.onEvent(name: "redirect.closed", payload: [:])
        if webView.canGoBack { webView.goBack() }
    }

    private func handleResult(_ result: GlomoPayResult) {
        didTerminate = true
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
        listener?.onConnectionError(error)
        analytics.trackConnectionError(error: error)
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
        analytics.trackPaymentTerminate(source: source)
        listener?.onPaymentTerminate(source)
        listener?.onEvent(name: "checkout.closed", payload: ["source": source.rawValue])
        dismiss(animated: true)
    }

    private func deliverSdkErrors(_ errors: [SdkError]) {
        didTerminate = true
        analytics.trackSdkError(errors: errors)
        listener?.onSdkError(errors)
        dismiss(animated: true)
    }
}
#endif
