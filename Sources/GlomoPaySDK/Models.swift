import Foundation

public struct GlomoPayConfig: Sendable, Equatable {
    public let publicKey: String
    public let orderId: String?
    public let subscriptionId: String?
    public let server: String?

    /// Whether a connectivity failure closes the checkout after reporting it.
    ///
    /// Reachable from the only documented entry point on purpose: it was a property on the
    /// checkout view controller, which `startCheckout` constructs internally and never exposes,
    /// so a merchant integrating from the README had no way to change it. The default closes,
    /// which is why the failure has to be worth closing for - an advisory load timeout and a
    /// cancelled navigation are not, and neither reaches this any more.
    public let autoCloseOnConnectionError: Bool

    public init(
        publicKey: String,
        orderId: String? = nil,
        subscriptionId: String? = nil,
        server: String? = nil,
        autoCloseOnConnectionError: Bool = true
    ) {
        self.publicKey = publicKey
        self.orderId = orderId
        self.subscriptionId = subscriptionId
        self.server = server
        self.autoCloseOnConnectionError = autoCloseOnConnectionError
    }

    public var checkoutId: String? { orderId ?? subscriptionId }
    public var isSubscription: Bool { !(subscriptionId?.isEmpty ?? true) }
}

public struct GlomoPayPayload: Equatable {
    public let orderId: String
    public let paymentId: String?
    public let signature: String?
    public let rawResponse: [String: AnyHashable]?

    public init(
        orderId: String,
        paymentId: String? = nil,
        signature: String? = nil,
        rawResponse: [String: AnyHashable]? = nil
    ) {
        self.orderId = orderId
        self.paymentId = paymentId
        self.signature = signature
        self.rawResponse = rawResponse
    }

    public init(json: [String: Any]) {
        let nested = json["payload"] as? [String: Any]
        let data = nested ?? json
        self.init(
            orderId: (data["orderId"] as? String) ?? (data["order_id"] as? String) ?? "",
            paymentId: (data["paymentId"] as? String) ?? (data["payment_id"] as? String),
            signature: data["signature"] as? String,
            rawResponse: json.reduce(into: [String: AnyHashable]()) { result, item in
                if let value = item.value as? AnyHashable { result[item.key] = value }
            }
        )
    }
}

// CheckoutStatus is deliberately absent. It was declared and referenced nowhere, and it carried
// the v1.11.2 member set - which reported a submitted bank transfer as paymentSuccessful and a
// backend decline as paymentFailed, telling a host a payment had completed or been declined when
// neither had happened. Shipping that shape as frozen public API was the one clearly wrong
// option, so it is gone rather than wired up.

public enum TerminationSource: String, Sendable {
    case userDismiss
    /// Host code called `close()` on the checkout handle returned by `startCheckout`.
    case programmatic
    case connectionError
    // No `backButton`: there is no native back control on the iOS checkout. The equivalent
    // escapes are the navigation bar's Close button and interactive sheet dismissal, both of
    // which report `userDismiss`.
}

public enum SdkErrorType: String, Sendable {
    case validationError
    case deviceForbidden
    case networkError
    case unknown
}

public struct SdkError: Error, Sendable, Equatable {
    public let type: SdkErrorType
    public let message: String
    public let field: String?

    public init(type: SdkErrorType, message: String, field: String? = nil) {
        self.type = type
        self.message = message
        self.field = field
    }
}

public enum ConnectionErrorType: String, Sendable {
    case noInternet
    case dnsFailure
    case timeout
    case sslError
    case httpClientError
    case httpServerError
    case webResourceError
    case unknown
}

public struct ConnectionError: Error, Sendable, Equatable {
    public let type: ConnectionErrorType
    public let message: String
    public let statusCode: Int?
    public let failedURL: URL?
    public let errorCode: Int?
    public let shouldAutoClose: Bool

    public init(
        type: ConnectionErrorType,
        message: String,
        statusCode: Int? = nil,
        failedURL: URL? = nil,
        errorCode: Int? = nil,
        shouldAutoClose: Bool = true
    ) {
        self.type = type
        self.message = message
        self.statusCode = statusCode
        self.failedURL = failedURL
        self.errorCode = errorCode
        self.shouldAutoClose = shouldAutoClose
    }

    public var isRecoverable: Bool {
        type == .noInternet || type == .timeout || type == .httpServerError
    }

    public static func fromHTTPStatus(_ statusCode: Int, failedURL: URL? = nil) -> ConnectionError {
        let type: ConnectionErrorType
        if (400..<500).contains(statusCode) {
            type = .httpClientError
        } else if (500..<600).contains(statusCode) {
            type = .httpServerError
        } else {
            type = .unknown
        }
        return ConnectionError(
            type: type,
            message: httpMessage(for: statusCode),
            statusCode: statusCode,
            failedURL: failedURL
        )
    }

    /// True when WebKit reported a navigation it cancelled itself rather than a failure.
    ///
    /// WebKit delivers `NSURLErrorCancelled` routinely, not exceptionally: on a superseded
    /// provisional navigation, on a client-side redirect during load, and on `stopLoading()`.
    /// It is not a connection error and must never reach the host or close the checkout.
    public static func isCancellation(domain: String, errorCode: Int) -> Bool {
        domain == NSURLErrorDomain && errorCode == NSURLErrorCancelled
    }

    public static func fromWebResourceError(
        description: String,
        errorCode: Int,
        failedURL: URL? = nil,
        domain: String = NSURLErrorDomain
    ) -> ConnectionError {
        let type: ConnectionErrorType
        switch (domain, errorCode) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            type = .noInternet
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            type = .dnsFailure
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            type = .timeout
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            type = .sslError
        default:
            type = .webResourceError
        }
        return ConnectionError(
            type: type,
            message: description,
            failedURL: failedURL,
            errorCode: errorCode,
            shouldAutoClose: autoCloses(type)
        )
    }

    /// Decided from the mapped type, never from the sign of the error code.
    ///
    /// The previous rule was `type != .webResourceError || errorCode < 0`, carried over from
    /// Chromium codes where the sign separated main-frame from resource failures. On iOS every
    /// `NSURLErrorDomain` code is negative, so every unmapped error closed the checkout, while
    /// `WKErrorDomain` codes are positive (1-15), so genuine WebKit failures were the ones
    /// exempted. Both halves were inverted.
    ///
    /// An unmapped or WebKit-internal failure now shows the retry surface instead of
    /// terminating, and a timeout does not self-close because the network may return.
    private static func autoCloses(_ type: ConnectionErrorType) -> Bool {
        switch type {
        case .noInternet, .dnsFailure, .sslError, .httpClientError, .httpServerError:
            return true
        case .timeout, .webResourceError, .unknown:
            return false
        }
    }

    private static func httpMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Page Not Found"
        case 408: return "Request Timeout"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "HTTP Error \(statusCode)"
        }
    }
}

/// Internal: the SDK's own terminal-result plumbing, constructed on every terminal path and
/// consumed only by the checkout controller. It was never handed to a host - the typed listener
/// callbacks are the contract - so it is not part of the public surface.
enum GlomoPayResult {
    case success(GlomoPayPayload)
    case failure(message: String, code: String?)
    /// A completed non-payment journey. Terminal like the others, but never a payment result.
    case userJourney(GlomoPayUserJourneyPayload)
    case cancelled
}

/// The SDK holds this weakly. Retain it for at least as long as the checkout, or its callbacks
/// cannot be delivered.
///
/// Callbacks arrive on the main queue and must not throw or trap: Swift has no catchable
/// exception mechanism, so a force-unwrap of nil or an out-of-range index inside a callback traps
/// the host process and the SDK cannot contain it.
///
/// There is no `onEvent`. The diagnostic channel it provided is not part of the integration
/// contract, and everything with diagnostic value goes to analytics and Sentry instead, which is
/// sanitised and does not depend on a host implementing anything.
public protocol GlomoPayListener: AnyObject {
    func onPaymentSuccess(_ payload: GlomoPayPayload)
    func onPaymentFailure(_ payload: GlomoPayPayload)
    func onSdkError(_ errors: [SdkError])
    func onConnectionError(_ error: ConnectionError)

    /// A non-payment journey completed - today, submitted bank-transfer details.
    ///
    /// Required, with no protocol-extension default, and that is deliberate even though the
    /// extension below carries a default for `onPaymentTerminate`. The SDK cannot tell which
    /// merchants have bank transfers enabled - the order decides that, server side - so a default
    /// body would let a host upgrade, keep compiling, and silently stop hearing about a journey it
    /// used to be told about through `onPaymentSuccess`.
    ///
    /// Nothing here is verifiable as a payment: there is no `paymentId`, no `signature`, and no
    /// money has moved. Reconcile it server-side against the order; never fulfil an order from it.
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload)

    func onPaymentTerminate(_ source: TerminationSource)
}

public extension GlomoPayListener {
    /// Optional: not every host distinguishes a dismissal from a result.
    func onPaymentTerminate(_ source: TerminationSource) {}
}
