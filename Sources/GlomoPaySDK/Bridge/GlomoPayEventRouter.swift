import Foundation

final class GlomoPayEventRouter {
    private weak var listener: GlomoPayListener?
    private let devMode: Bool
    private let onComplete: (GlomoPayResult) -> Void
    private let onWindowOpen: (URL) -> Void
    private let onWindowClose: () -> Void
    private var terminalDelivered = false

    init(
        listener: GlomoPayListener?,
        devMode: Bool,
        onComplete: @escaping (GlomoPayResult) -> Void,
        onWindowOpen: @escaping (URL) -> Void = { _ in },
        onWindowClose: @escaping () -> Void = {}
    ) {
        self.listener = listener
        self.devMode = devMode
        self.onComplete = onComplete
        self.onWindowOpen = onWindowOpen
        self.onWindowClose = onWindowClose
    }

    func handle(body: Any) {
        do {
            let envelope = try dictionary(from: body)
            handle(envelope: envelope)
        } catch {
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
            if devMode { emit("console", envelope) }
        case "window.open":
            if let rawURL = envelope["url"] as? String, let url = URL(string: rawURL) {
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
            emit("checkout.dependencies_failed", [
                "message": envelope["message"] as? String ?? "Checkout dependencies failed to load",
                "source": "bridge",
            ])
        case "file.input":
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
            guard Validator.isValidPaymentPayload(payload) else {
                emitError(message: "Invalid payment success payload")
                return
            }
            complete(.success(payload))
        case "payment.bank_transfer_submitted":
            let payload = GlomoPayPayload(json: payloadData)
            guard !payload.orderId.isEmpty else {
                emitError(message: "Invalid bank transfer payload")
                return
            }
            complete(.success(payload))
        case "payment.failure", "payment.failed", "failed", "payment.error":
            let payload = GlomoPayPayload(json: payloadData)
            guard Validator.isValidPaymentPayload(payload) else {
                emitError(message: "Invalid payment failure payload")
                return
            }
            complete(.failure(message: "Payment failed", code: nil), payload: payload)
        case "payment.pending", "pending":
            break
        case "payment.cancelled", "cancelled", "checkout.closed":
            complete(.cancelled, termination: .userDismiss)
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
        listener?.onSdkError([SdkError(type: .unknown, message: message)])
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
