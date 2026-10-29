import Foundation

enum AnalyticsCatalogue {
    static let integration = "ios_sdk"
    static let platform = "ios"
    static let orderAPIPath = "/api/public/v1/order/:order_id"

    static let eventNames: Set<String> = [
        AnalyticsEventName.sdkLoaded,
        AnalyticsEventName.sdkPageViewed,
        AnalyticsEventName.sdkAPIBackend,
        AnalyticsEventName.sdkActionSubmitted,
        AnalyticsEventName.sdkActionFailed,
        AnalyticsEventName.sdkCTAClicked,
        AnalyticsEventName.sdkControlChanged,
        AnalyticsEventName.sdkCheckoutFailed,
        AnalyticsEventName.sdkCheckoutClosed,
    ]

    static func onceKey(event: String, properties: [String: Any?]) -> String? {
        switch event {
        case AnalyticsEventName.sdkLoaded, AnalyticsEventName.sdkCheckoutClosed:
            return event
        case AnalyticsEventName.sdkCheckoutFailed:
            return "\(event):\(stringValue(properties["error_code"] ?? nil) ?? "")"
        case AnalyticsEventName.sdkPageViewed:
            let page = stringValue(properties["page_name"] ?? nil)
            guard page == AnalyticsPageName.checkout.rawValue || page == AnalyticsPageName.educationCarousel.rawValue
            else { return nil }
            return "\(event):\(page ?? "")"
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }
}

enum AnalyticsPageName: String, CaseIterable {
    case loading
    case checkout
    case bankRedirect = "bank_redirect"
    case educationCarousel = "education_carousel"
    case error
}

enum AnalyticsCTAName: String, CaseIterable {
    case retry
    case backToCheckout = "back_to_checkout"
}

enum AnalyticsActionName: String, CaseIterable {
    case bankRedirect = "bank_redirect"
    case webViewLoad = "webview_load"
    case navigation
    case paymentPayload = "payment_payload"
    case educationCarousel = "education_carousel"
}

enum AnalyticsCloseTrigger: String, CaseIterable {
    case userDismiss = "user_dismiss"
    case merchant
    case sdk
}

enum AnalyticsPaymentEvent: String, CaseIterable {
    case paymentSuccess = "payment_success"
    case paymentFailure = "payment_failure"
    case bankTransferSubmitted = "bank_transfer_submitted"
}

enum AnalyticsWebViewType: String, CaseIterable {
    case main
    case flow
}

enum AnalyticsLoadError: String, CaseIterable {
    case connectionError = "connection_error"
    case httpError = "http_error"
    case contentProcessTerminated = "content_process_terminated"
}

enum AnalyticsErrorPageCode: String, CaseIterable {
    case connectionError = "connection_error"
    case httpError = "http_error"
    case webViewError = "webview_error"
    case contentProcessTerminated = "content_process_terminated"
    case openTimeout = "open_timeout"
    case other

    init(_ failure: AnalyticsLoadError) {
        switch failure {
        case .connectionError: self = .connectionError
        case .httpError: self = .httpError
        case .contentProcessTerminated: self = .contentProcessTerminated
        }
    }
}

enum AnalyticsNavigationError: String, CaseIterable {
    case nonHTTPScheme = "non_http_scheme"
    case invalidWindowOpenURL = "invalid_window_open_url"
}

enum AnalyticsPaymentPayloadError: String, CaseIterable {
    case dropped
}

enum AnalyticsEducationCarouselError: String, CaseIterable {
    case webViewError = "webview_error"
    case contentProcessTerminated = "content_process_terminated"
    case renderFailed = "render_failed"
    case other

    init(pageReason: Any?) {
        guard let reason = pageReason as? String else {
            self = .renderFailed
            return
        }
        self = Self(rawValue: reason) ?? .other
    }
}

enum AnalyticsAPIError: String, CaseIterable {
    case timeout
    case network
    case httpError = "http_error"
    case invalidResponse = "invalid_response"

    init?(_ error: GlomoPayAPIError) {
        switch error {
        case .requestTimeout: self = .timeout
        case .transport: self = .network
        case .failedToLoadOrder: self = .httpError
        case .invalidOrderResponse: self = .invalidResponse
        case .invalidOrderURL: return nil
        }
    }
}

enum AnalyticsInvalidInitParams: String, CaseIterable {
    case invalidPublicKey = "invalid_public_key"
    case missingOrderID = "missing_order_id"
    case invalidOrderID = "invalid_order_id"
    case invalidServer = "invalid_server"
    case other

    init(_ error: SdkError?) {
        switch error?.field {
        case "publicKey": self = .invalidPublicKey
        case "orderId", "subscriptionId": self = .invalidOrderID
        case "identifier": self = .missingOrderID
        case "server": self = .invalidServer
        default: self = .other
        }
    }
}

enum AnalyticsComplianceBlock: String, CaseIterable {
    case jailbreakDetected = "jailbreak_detected"
    case debuggerAttached = "debugger_attached"
}

enum AnalyticsOrderFetchFailure: String, CaseIterable {
    case timeout
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case network
    case invalidResponse = "invalid_response"
    case other

    init(_ error: Error) {
        guard let apiError = error as? GlomoPayAPIError else {
            self = .other
            return
        }
        switch apiError {
        case .requestTimeout: self = .timeout
        case .transport: self = .network
        case let .failedToLoadOrder(statusCode): self = Self(statusCode: statusCode)
        case .invalidOrderResponse: self = .invalidResponse
        case .invalidOrderURL: self = .other
        }
    }

    private init(statusCode: Int) {
        if (400..<500).contains(statusCode) {
            self = .http4xx
        } else if (500..<600).contains(statusCode) {
            self = .http5xx
        } else {
            self = .other
        }
    }
}

enum AnalyticsConnectionFailure: String, CaseIterable {
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case network

    init(_ error: ConnectionError) {
        if let statusCode = error.statusCode, (400..<500).contains(statusCode) {
            self = .http4xx
        } else if let statusCode = error.statusCode, (500..<600).contains(statusCode) {
            self = .http5xx
        } else {
            self = .network
        }
    }
}

enum AnalyticsCheckoutFailure {
    case invalidInitParams(AnalyticsInvalidInitParams)
    case dependenciesFailedToLoad
    case complianceBlocked(AnalyticsComplianceBlock)
    case orderFetchFailed(AnalyticsOrderFetchFailure)
    case openTimeout(lastStep: String)
    case connectionError(AnalyticsConnectionFailure)

    static let errorCodes = [
        "invalid_init_params",
        "dependencies_failed_to_load",
        "compliance_blocked",
        "order_fetch_failed",
        "open_timeout",
        "connection_error",
    ]

    var errorCode: String {
        switch self {
        case .invalidInitParams: return "invalid_init_params"
        case .dependenciesFailedToLoad: return "dependencies_failed_to_load"
        case .complianceBlocked: return "compliance_blocked"
        case .orderFetchFailed: return "order_fetch_failed"
        case .openTimeout: return "open_timeout"
        case .connectionError: return "connection_error"
        }
    }

    var properties: [String: Any?] {
        switch self {
        case let .invalidInitParams(detail):
            return ["error_code": errorCode, "error_detail": detail.rawValue]
        case .dependenciesFailedToLoad:
            return ["error_code": errorCode]
        case let .complianceBlocked(detail):
            return ["error_code": errorCode, "error_detail": detail.rawValue]
        case let .orderFetchFailed(detail):
            return ["error_code": errorCode, "error_detail": detail.rawValue]
        case let .openTimeout(lastStep):
            return ["error_code": errorCode, "last_step": lastStep]
        case let .connectionError(detail):
            return ["error_code": errorCode, "error_detail": detail.rawValue]
        }
    }
}

enum AnalyticsActionFailure {
    case webViewLoad(
        AnalyticsLoadError,
        webViewType: AnalyticsWebViewType,
        httpStatus: Int? = nil,
        isRecoverable: Bool? = nil,
        urlOrigin: String? = nil
    )
    case navigation(AnalyticsNavigationError, scheme: String, webViewType: AnalyticsWebViewType)
    case paymentPayload(AnalyticsPaymentPayloadError, pageEvent: AnalyticsPaymentEvent)
    case educationCarousel(AnalyticsEducationCarouselError)

    var properties: [String: Any?] {
        switch self {
        case let .webViewLoad(error, webViewType, httpStatus, isRecoverable, urlOrigin):
            return [
                "action_name": AnalyticsActionName.webViewLoad.rawValue,
                "error_code": error.rawValue,
                "webview_type": webViewType.rawValue,
                "http_status": httpStatus,
                "is_recoverable": isRecoverable,
                "url_origin": urlOrigin,
            ]
        case let .navigation(error, scheme, webViewType):
            return [
                "action_name": AnalyticsActionName.navigation.rawValue,
                "error_code": error.rawValue,
                "scheme": scheme,
                "webview_type": webViewType.rawValue,
            ]
        case let .paymentPayload(error, pageEvent):
            return [
                "action_name": AnalyticsActionName.paymentPayload.rawValue,
                "error_code": error.rawValue,
                "page_event": pageEvent.rawValue,
            ]
        case let .educationCarousel(error):
            return [
                "action_name": AnalyticsActionName.educationCarousel.rawValue,
                "error_code": error.rawValue,
            ]
        }
    }
}

extension AnalyticsTracking {
    func trackSDKLoaded() {
        track(AnalyticsEventName.sdkLoaded, properties: [:])
    }

    func trackPageViewed(_ page: AnalyticsPageName, urlOrigin: String? = nil, errorCode: AnalyticsErrorPageCode? = nil) {
        track(AnalyticsEventName.sdkPageViewed, properties: present([
            "page_name": page.rawValue,
            "url_origin": urlOrigin,
            "error_code": errorCode?.rawValue,
        ]))
    }

    func trackOrderFetchSucceeded(httpStatus: Int) {
        track(AnalyticsEventName.sdkAPIBackend, properties: [
            "api_path": AnalyticsCatalogue.orderAPIPath,
            "http_method": "GET",
            "status": "succeeded",
            "http_status": httpStatus,
        ])
    }

    func trackOrderFetchFailed(_ error: AnalyticsAPIError, httpStatus: Int?) {
        track(AnalyticsEventName.sdkAPIBackend, properties: present([
            "api_path": AnalyticsCatalogue.orderAPIPath,
            "http_method": "GET",
            "status": "failed",
            "error_code": error.rawValue,
            "http_status": httpStatus,
        ]))
    }

    func trackBankRedirectSubmitted(urlOrigin: String?) {
        track(AnalyticsEventName.sdkActionSubmitted, properties: present([
            "action_name": AnalyticsActionName.bankRedirect.rawValue,
            "url_origin": urlOrigin,
        ]))
    }

    func trackActionFailed(_ failure: AnalyticsActionFailure) {
        track(AnalyticsEventName.sdkActionFailed, properties: present(failure.properties))
    }

    func trackCTAClicked(_ cta: AnalyticsCTAName, page: AnalyticsPageName) {
        track(AnalyticsEventName.sdkCTAClicked, properties: [
            "cta_name": cta.rawValue,
            "page_name": page.rawValue,
        ])
    }

    func trackColorSchemeChanged(newValue: String, previousValue: String, appColorScheme: String) {
        track(AnalyticsEventName.sdkControlChanged, properties: [
            "control_name": "color_scheme",
            "new_value": newValue,
            "previous_value": previousValue,
            "app_color_scheme": appColorScheme,
        ])
    }

    func trackCheckoutFailed(_ failure: AnalyticsCheckoutFailure) {
        track(AnalyticsEventName.sdkCheckoutFailed, properties: failure.properties)
    }

    func trackCheckoutClosed(
        _ trigger: AnalyticsCloseTrigger,
        page: AnalyticsPageName,
        paymentEvent: AnalyticsPaymentEvent? = nil,
        hadListener: Bool? = nil
    ) {
        track(AnalyticsEventName.sdkCheckoutClosed, properties: present([
            "trigger": trigger.rawValue,
            "page_name": page.rawValue,
            "payment_event": paymentEvent?.rawValue,
            "had_listener": hadListener,
        ]))
    }

    private func present(_ properties: [String: Any?]) -> [String: Any?] {
        properties.filter { $0.value != nil }
    }
}
