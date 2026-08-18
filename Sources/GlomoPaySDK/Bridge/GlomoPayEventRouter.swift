import Foundation

final class GlomoPayEventRouter {
    private weak var listener: GlomoPayListener?
    private let devMode: Bool
    private let onComplete: (GlomoPayResult) -> Void
    private let onWindowOpen: (URL) -> Void
    private let onWindowClose: () -> Void
    private let analytics: AnalyticsTracking
    private let errorReporter: SDKErrorReporting
    private var terminalDelivered = false

    init(
        listener: GlomoPayListener?,
        devMode: Bool,
        onComplete: @escaping (GlomoPayResult) -> Void,
        onWindowOpen: @escaping (URL) -> Void = { _ in },
        onWindowClose: @escaping () -> Void = {},
        analytics: AnalyticsTracking = NoOpAnalyticsTracker(),
        errorReporter: SDKErrorReporting = NoOpSDKErrorReporter()
    ) {
        self.listener = listener
        self.devMode = devMode
        self.onComplete = onComplete
        self.onWindowOpen = onWindowOpen
        self.onWindowClose = onWindowClose
        self.analytics = analytics
        self.errorReporter = errorReporter
    }

    func handle(body: Any) {
        do {
            let envelope = try dictionary(from: body)
            handle(envelope: envelope)
        } catch {
            analytics.track(AnalyticsEventName.invalidMessageReceived, properties: [
                "webview_type": "main",
                "data": AnalyticsSanitizer.text(String(describing: body), limit: 500),
                "data_type": String(describing: type(of: body)),
            ])
            emitError(message: error.localizedDescription)
        }
    }

    func handle(envelope: [String: Any]) {
        guard let type = envelope["type"] as? String, !type.isEmpty else {
            emitError(message: "Bridge message is missing a type")
            return
        }

        switch type {
        case "console":
            if devMode {
                analytics.track(AnalyticsEventName.consoleLogCaptured, properties: [
                    "level": envelope["level"] as? String,
                    "message": AnalyticsSanitizer.text(envelope["message"] as? String ?? "", limit: 1_000),
                ])
                emit("console", envelope)
            }
        case "window.open":
            if let rawURL = envelope["url"] as? String, let url = URL(string: rawURL) {
                analytics.track(AnalyticsEventName.redirectOpened, properties: [
                    "source": "main",
                    "url": AnalyticsSanitizer.bankRedirectURL(url),
                ])
                onWindowOpen(url)
                emit("redirect.started", ["url": rawURL])
            } else {
                emitError(message: "window.open has an invalid URL")
            }
        case "window.close":
            onWindowClose()
            emit("redirect.completed", [:])
        case "message":
            if let data = envelope["data"] as? [String: Any] {
                handlePaymentEvent(data)
            }
        case "dependencies.failed_to_load":
            let message = envelope["message"] as? String ?? "Checkout dependencies failed to load"
            analytics.track(AnalyticsEventName.checkoutDependenciesFailed, properties: ["error_message": message])
            errorReporter.capture(
                operation: "checkout_dependencies",
                error: RouterError(message),
                context: ["source": "bridge"]
            )
            emit("checkout.dependencies_failed", [
                "message": message,
                "source": "bridge",
            ])
        case "file.input":
            analytics.track(AnalyticsEventName.fileUploadRequested, properties: [
                "accept_types": envelope["accept"] as? String,
            ])
            emit("file.requested", envelope)
        default:
            emit(type, envelope)
        }
    }

    private func handlePaymentEvent(_ data: [String: Any]) {
        let eventName = (data["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? data["event"] as? String
            ?? data["status"] as? String

        if let eventName { emit(eventName, data) }

        var payloadData = data
        if let nested = data["payload"] as? [String: Any] {
            payloadData.merge(nested) { _, nestedValue in nestedValue }
        }

        switch eventName {
        case "payment.success", "success":
            let payload = GlomoPayPayload(json: payloadData)
            analytics.track(AnalyticsEventName.paymentSuccess, properties: ["payment_id": payload.paymentId])
            guard Validator.isValidPaymentPayload(payload) else {
                emitError(message: "Invalid payment success payload")
                return
            }
            complete(.success(payload))
        case "payment.bank_transfer_submitted":
            let payload = GlomoPayPayload(json: payloadData)
            analytics.track(AnalyticsEventName.bankTransferSubmitted)
            guard !payload.orderId.isEmpty else {
                emitError(message: "Invalid bank transfer payload")
                return
            }
            complete(.success(payload))
        case "payment.failure", "payment.failed", "failed", "payment.error":
            let payload = GlomoPayPayload(json: payloadData)
            analytics.track(AnalyticsEventName.paymentFailure, properties: [
                "payment_id": payload.paymentId,
                "reason": payloadData["reason"] ?? payloadData["message"],
            ])
            guard Validator.isValidPaymentPayload(payload) else {
                emitError(message: "Invalid payment failure payload")
                return
            }
            complete(.failure(message: "Payment failed", code: nil), payload: payload)
        case "payment.pending", "pending":
            let payload = GlomoPayPayload(json: payloadData)
            analytics.track(AnalyticsEventName.paymentPending, properties: ["payment_id": payload.paymentId])
            break
        case "payment.cancelled", "cancelled":
            analytics.track(AnalyticsEventName.paymentCancelled)
            complete(.cancelled, termination: .userDismiss)
        case "checkout.closed":
            analytics.track(AnalyticsEventName.paymentTerminated, properties: [
                "termination_source": "checkout_closed",
            ])
            complete(.cancelled, termination: .userDismiss)
        case "glomoCheckoutJourneyTerminate":
            analytics.track(AnalyticsEventName.payViaBankCompleted, properties: [
                "pay_via_bank_status": payloadData["status"],
            ])
        case "lrs.has_education_steps":
            if payloadData["value"] as? Bool == true {
                analytics.track(AnalyticsEventName.educationStepsShown, properties: [
                    "source": payloadData["source"],
                ])
            }
        case "lrs.education_steps_failed", "lrs.education_steps_failed_to_show":
            analytics.track(AnalyticsEventName.educationStepsFailed, properties: [
                "reason": payloadData["reason"] ?? "render_failed",
            ])
        case "dependencies.failed_to_load":
            let message = payloadData["message"] as? String ?? "Checkout dependencies failed to load"
            analytics.track(AnalyticsEventName.checkoutDependenciesFailed, properties: ["error_message": message])
        default:
            break
        }
    }

    @discardableResult
    private func complete(_ result: GlomoPayResult, payload: GlomoPayPayload? = nil, termination: TerminationSource? = nil) -> Bool {
        guard !terminalDelivered else { return false }
        terminalDelivered = true
        switch result {
        case .success(let payload):
            listener?.onPaymentSuccess(payload)
        case .failure:
            if let payload { listener?.onPaymentFailure(payload) }
        case .cancelled:
            listener?.onPaymentTerminate(termination ?? .userDismiss)
        }
        onComplete(result)
        return true
    }

    private func emit(_ name: String, _ payload: [String: Any]) {
        listener?.onEvent(name: name, payload: payload)
    }

    private func emitError(message: String) {
        let error = SdkError(type: .unknown, message: message)
        let serialized = "[{\"type\":\"unknown\",\"message\":\"\(AnalyticsSanitizer.text(message, limit: 500))\"}]"
        analytics.track(AnalyticsEventName.sdkError, properties: [
            "error_count": 1,
            "errors": serialized,
        ])
        errorReporter.capture(operation: "bridge_message", error: error, context: ["error_type": "unknown"])
        listener?.onSdkError([error])
    }

    private func dictionary(from body: Any) throws -> [String: Any] {
        if let dictionary = body as? [String: Any] { return dictionary }
        if let string = body as? String,
           let data = string.data(using: .utf8),
           let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dictionary
        }
        throw NSError(domain: "GlomoPayBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to parse WebView bridge message"])
    }
}

private struct RouterError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
