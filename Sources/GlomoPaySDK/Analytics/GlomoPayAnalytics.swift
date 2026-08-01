import Foundation

public enum GlomoPayAnalyticsEvents {
    public static let startAttempt = "Checkout Start Attempted"
    public static let startSuccess = "Checkout Started"
    public static let startFailure = "Checkout Start Failed"
    public static let windowOpen = "Checkout Window Open"
    public static let windowClose = "Checkout Window Close"
    public static let invalidMessage = "Checkout Invalid Message Received"
    public static let paymentSuccess = "Payment Success"
    public static let paymentFailure = "Payment Failure"
    public static let paymentTerminate = "Payment Terminated"
    public static let connectionError = "Connection Error"
    public static let sdkError = "SDK Error"
    public static let bankTransferSubmitted = "Bank Transfer Submitted"
}

public protocol GlomoPayAnalyticsTransport {
    func send(eventName: String, properties: [String: Any], context: [String: Any])
}

/// Best-effort Segment transport. Telemetry never blocks checkout.
public final class GlomoPaySegmentTransport: GlomoPayAnalyticsTransport {
    public static let defaultWriteKey = "gjfGYZSnEkTr1nf3XajHaRab1oG1mIHN"

    private let writeKey: String
    private let session: URLSession

    public init(writeKey: String = GlomoPaySegmentTransport.defaultWriteKey, session: URLSession = .shared) {
        self.writeKey = writeKey
        self.session = session
    }

    public func send(eventName: String, properties: [String: Any], context: [String: Any]) {
        guard let url = URL(string: "https://api.segment.io/v1/track") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(writeKey):".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let anonymousID = properties["anonymous_id"] as? String ?? UUID().uuidString
        let body: [String: Any] = [
            "type": "track",
            "messageId": "glomo_\(anonymousID)_\(UUID().uuidString)",
            "anonymousId": anonymousID,
            "event": eventName,
            "properties": properties,
            "context": context,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sentAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data
        session.dataTask(with: request) { _, response, error in
            if let error {
                GlomoPayLogger.error("Analytics delivery failed", error: error)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            GlomoPayLogger.analytics(statusCode >= 200 && statusCode < 300
                ? "Event sent: \(eventName)"
                : "Event delivery failed: \(eventName)")
        }.resume()
    }
}

public final class GlomoPayAnalytics {
    public static let sdkVersion = "1.0.0"

    private let devMode: Bool
    private let enabled: Bool
    private let transport: GlomoPayAnalyticsTransport
    private let queue = DispatchQueue(label: "com.glomopay.sdk.analytics", qos: .utility)
    private let anonymousID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var orderID: String?
    private var publicKey: String?
    private var checkoutURL: String?
    private var checkoutType: String?
    private var mockMode = false
    private var isJailbroken: Bool?

    public init(
        devMode: Bool,
        enabled: Bool = true,
        transport: GlomoPayAnalyticsTransport? = nil
    ) {
        self.devMode = devMode
        self.enabled = enabled
        self.transport = transport ?? GlomoPaySegmentTransport()
        GlomoPayLogger.devMode = devMode
    }

    public func setCheckoutContext(
        orderID: String? = nil,
        publicKey: String? = nil,
        checkoutURL: String? = nil,
        checkoutType: String? = nil,
        mockMode: Bool? = nil,
        isJailbroken: Bool? = nil
    ) {
        if let orderID { self.orderID = orderID }
        if let publicKey { self.publicKey = publicKey }
        if let checkoutURL { self.checkoutURL = checkoutURL }
        if let checkoutType { self.checkoutType = checkoutType }
        if let mockMode { self.mockMode = mockMode }
        if let isJailbroken { self.isJailbroken = isJailbroken }
    }

    public func trackEvent(_ name: String, additionalProperties: [String: Any] = [:]) {
        guard enabled else { return }
        let properties = eventProperties(additionalProperties)
        let context = deviceContext()
        queue.async { [transport] in
            transport.send(eventName: name, properties: properties, context: context)
        }
    }

    public func trackStartAttempt() { trackEvent(GlomoPayAnalyticsEvents.startAttempt) }
    public func trackStartSuccess() { trackEvent(GlomoPayAnalyticsEvents.startSuccess) }

    public func trackStartFailure(reason: String? = nil, errorCode: String? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.startFailure, additionalProperties: compact([
            "reason": reason, "error_code": errorCode,
        ]))
    }

    public func trackWindowOpen(url: String? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.windowOpen, additionalProperties: compact(["url": url]))
    }

    public func trackWindowClose() { trackEvent(GlomoPayAnalyticsEvents.windowClose) }

    public func trackInvalidMessage(message: String? = nil, error: String? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.invalidMessage, additionalProperties: compact([
            "message": message, "error": error,
        ]))
    }

    public func trackPaymentSuccess(payload: GlomoPayPayload? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.paymentSuccess, additionalProperties: compact([
            "payload_order_id": payload?.orderId,
        ]))
    }

    public func trackPaymentFailure(payload: GlomoPayPayload? = nil, reason: String? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.paymentFailure, additionalProperties: compact([
            "payload_order_id": payload?.orderId, "reason": reason,
        ]))
    }

    public func trackBankTransferSubmitted(payload: GlomoPayPayload? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.bankTransferSubmitted, additionalProperties: compact([
            "payload_order_id": payload?.orderId,
        ]))
    }

    public func trackPaymentTerminate(source: TerminationSource? = nil) {
        trackEvent(GlomoPayAnalyticsEvents.paymentTerminate, additionalProperties: compact([
            "termination_source": source?.rawValue,
        ]))
    }

    public func trackConnectionError(error: ConnectionError? = nil) {
        var properties: [String: Any] = [:]
        if let error {
            properties = [
                "error_type": error.type.rawValue,
                "error_message": error.message,
                "error_code": error.errorCode as Any,
                "is_recoverable": error.isRecoverable,
            ]
        }
        trackEvent(GlomoPayAnalyticsEvents.connectionError, additionalProperties: properties)
    }

    public func trackSdkError(errors: [SdkError] = []) {
        var properties: [String: Any] = [:]
        if let first = errors.first {
            properties = [
                "error_count": errors.count,
                "first_error_type": first.type.rawValue,
                "first_error_message": first.message,
            ]
        }
        trackEvent(GlomoPayAnalyticsEvents.sdkError, additionalProperties: properties)
    }

    private func eventProperties(_ additional: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "sdk_version": Self.sdkVersion,
            "platform": "ios",
            "dev_mode": devMode,
            "mock_mode": mockMode,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "anonymous_id": anonymousID,
        ]
        if let orderID { result["order_id"] = orderID }
        if let publicKey { result["public_key"] = publicKey }
        if let checkoutURL { result["checkout_url"] = checkoutURL }
        if let checkoutType { result["checkout_type"] = checkoutType }
        if let isJailbroken { result["is_jailbroken"] = isJailbroken }
        result.merge(additional) { _, new in new }
        return result
    }

    private func deviceContext() -> [String: Any] {
        let processInfo = ProcessInfo.processInfo
        return [
            "library": ["name": "analytics-ios", "version": Self.sdkVersion],
            "app": ["name": "GlomoPay iOS SDK", "version": Self.sdkVersion, "build": "1", "namespace": publicKey ?? "glomopay_sdk"],
            "device": ["model": processInfo.machineHardwareName, "name": processInfo.hostName, "type": "ios"],
            "os": ["name": "iOS", "version": processInfo.operatingSystemVersionString],
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
        ]
    }

    private func compact(_ values: [String: Any?]) -> [String: Any] {
        values.compactMapValues { $0 }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iOS Device"
    }
}
