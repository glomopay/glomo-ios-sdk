import Foundation

public struct GlomoPayConfig: Sendable, Equatable {
    public let publicKey: String
    public let orderId: String?
    public let subscriptionId: String?
    public let server: String?
    public let devMode: Bool

    public init(
        publicKey: String,
        orderId: String? = nil,
        subscriptionId: String? = nil,
        server: String? = nil,
        devMode: Bool = false
    ) {
        self.publicKey = publicKey
        self.orderId = orderId
        self.subscriptionId = subscriptionId
        self.server = server
        self.devMode = devMode
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

public enum CheckoutStatus: String, Sendable {
    case ready
    case validating
    case paymentInProgress
    case paymentSuccessful
    case paymentFailed
    case paymentCancelled
}

public enum TerminationSource: String, Sendable {
    case userDismiss
    case backButton
    case programmatic
    case connectionError
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

    public static func fromWebResourceError(
        description: String,
        errorCode: Int,
        failedURL: URL? = nil
    ) -> ConnectionError {
        let type: ConnectionErrorType
        switch errorCode {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            type = .noInternet
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            type = .dnsFailure
        case NSURLErrorTimedOut:
            type = .timeout
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            type = .sslError
        default:
            type = .webResourceError
        }
        return ConnectionError(
            type: type,
            message: description,
            failedURL: failedURL,
            errorCode: errorCode,
            shouldAutoClose: type != .webResourceError || errorCode < 0
        )
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

public enum GlomoPayResult {
    case success(GlomoPayPayload)
    case failure(message: String, code: String?)
    case cancelled
}

public protocol GlomoPayListener: AnyObject {
    func onPaymentSuccess(_ payload: GlomoPayPayload)
    func onPaymentFailure(_ payload: GlomoPayPayload)
    func onSdkError(_ errors: [SdkError])
    func onConnectionError(_ error: ConnectionError)
    func onPaymentTerminate(_ source: TerminationSource)
    func onEvent(name: String, payload: [String: Any])
}

public extension GlomoPayListener {
    func onPaymentTerminate(_ source: TerminationSource) {}
    func onEvent(name: String, payload: [String: Any]) {}
}
