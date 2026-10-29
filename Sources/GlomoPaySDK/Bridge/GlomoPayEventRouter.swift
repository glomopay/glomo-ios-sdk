import Foundation

final class GlomoPayEventRouter {
    private weak var listener: GlomoPayListener?
    private let onComplete: (GlomoPayResult) -> Void
    private let onWindowOpen: (URL) -> Void
    private let onWindowClose: () -> Void
    private let onBridgeReady: () -> Void
    private let analytics: AnalyticsTracking
    private let errorReporter: SDKErrorReporting
    private var terminalDelivered = false

    init(
        listener: GlomoPayListener?,
        onComplete: @escaping (GlomoPayResult) -> Void,
        onWindowOpen: @escaping (URL) -> Void = { _ in },
        onWindowClose: @escaping () -> Void = {},
        onBridgeReady: @escaping () -> Void = {},
        analytics: AnalyticsTracking,
        errorReporter: SDKErrorReporting
    ) {
        self.listener = listener
        self.onComplete = onComplete
        self.onWindowOpen = onWindowOpen
        self.onWindowClose = onWindowClose
        self.onBridgeReady = onBridgeReady
        self.analytics = analytics
        self.errorReporter = errorReporter
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
        case "bridge.ready":
            // "The page is alive" is known here, by which case received the message - no host
            // event channel and no unprefixed-name heuristic needed to derive it.
            onBridgeReady()
        case "window.open":
            // URL(string:) is a parse, not a check: it happily returns a valid URL for
            // javascript:, data: and file:. Validate before anything can navigate.
            guard let rawURL = envelope["url"] as? String,
                  Validator.isValidUrl(rawURL),
                  let url = URL(string: rawURL) else {
                let scheme = (envelope["url"] as? String)
                    .flatMap { URLComponents(string: $0)?.scheme?.lowercased() } ?? "none"
                analytics.trackActionFailed(.navigation(.invalidWindowOpenURL, scheme: scheme, webViewType: .main))
                // A page sending an unusable window.open URL is a contract break, not noise:
                // Flutter drops it silently and that is the part not worth copying.
                errorReporter.capture(
                    operation: "window_open_rejected",
                    error: RouterError("window.open URL rejected"),
                    context: ["scheme": scheme]
                )
                emitError(message: "window.open has an invalid URL")
                return
            }
            analytics.trackPageViewed(.bankRedirect, urlOrigin: AnalyticsSanitizer.bankRedirectURL(url))
            onWindowOpen(url)
        case "window.close":
            onWindowClose()
        case "message":
            if let data = envelope["data"] as? [String: Any] {
                handlePaymentEvent(data)
            }
        case "dependencies.failed_to_load":
            let message = envelope["message"] as? String ?? "Checkout dependencies failed to load"
            analytics.trackCheckoutFailed(.dependenciesFailedToLoad)
            errorReporter.capture(
                operation: "checkout_dependencies",
                error: RouterError(message),
                context: ["source": "bridge"]
            )
        default:
            break
        }
    }

    private func handlePaymentEvent(_ data: [String: Any]) {
        let eventName = (data["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? data["event"] as? String
            ?? data["status"] as? String


        var payloadData = data
        if let nested = data["payload"] as? [String: Any] {
            payloadData.merge(nested) { _, nestedValue in nestedValue }
        }

        switch eventName {
        case "payment.success", "success":
            let payload = GlomoPayPayload(json: payloadData)
            guard Validator.isValidPaymentPayload(payload) else {
                analytics.trackActionFailed(.paymentPayload(.dropped, pageEvent: .paymentSuccess))
                emitError(message: "Invalid payment success payload")
                return
            }
            complete(.success(payload))
        // A submitted bank transfer is a journey, not a payment: there is no paymentId and no
        // signature, so there is nothing a host's backend can verify. Reporting it through
        // onPaymentSuccess told merchants money had moved when it had not.
        case "payment.bank_transfer_submitted":
            let journey = GlomoPayUserJourneyPayload(
                journeyType: .bankTransferSubmitted,
                json: payloadData
            )
            guard !journey.orderId.isEmpty else {
                // Rejected, but never silently, and not as a generic SDK error either: a dropped
                // journey must leave a trace that says which journey it was.
                errorReporter.capture(
                    operation: "thin_bank_transfer_payload",
                    error: RouterError("Bank transfer payload carried no orderId"),
                    context: ["keys": SentryScrubber.schemaKeys(Array(payloadData.keys)).joined(separator: ",")]
                )
                return
            }
            complete(.userJourney(journey))
        // Delivered on the event name alone. The previous rule also required a signature, which a
        // failure payload has never carried - that field exists so a host can verify a success -
        // so onPaymentFailure never fired for a confirmed decline, and the host got an
        // onSdkError describing the SDK's own guard instead. Do not substitute another schema
        // check here: replacing one guess about the page's schema with another invites the same
        // silent misroute the next time that schema moves.
        case "payment.failure", "payment.failed", "failed", "payment.error":
            let payload = GlomoPayPayload(json: payloadData)
            if payload.orderId.isEmpty {
                errorReporter.capture(
                    operation: "thin_payment_failure_payload",
                    error: RouterError("Payment failure payload carried no orderId"),
                    context: ["keys": SentryScrubber.schemaKeys(Array(payloadData.keys)).joined(separator: ",")]
                )
            }
            // Delivered either way: the payload travels as-is in rawResponse.
            complete(.failure(message: "Payment failed", code: nil), payload: payload)
        case "payment.pending", "pending":
            break
        case "payment.cancelled", "cancelled", "checkout.closed":
            complete(.cancelled, termination: .userDismiss)
        // No `glomoCheckoutJourneyTerminate` case. Pay-via-bank is sunset and unsupported on iOS:
        // the event used to be tracked as Pay Via Bank Completed with no callback, no payload type
        // and no enum member behind it, which made a dashboard show a live-looking signal for a
        // journey no merchant is told about. If the page still emits it, it now falls through to
        // the default branch and is ignored, which is the correct outcome.
        case "lrs.has_education_steps":
            // The page's contract is { type: 'lrs.has_education_steps', value: true }, sent only
            // when there is content; anything else is not a signal.
            if EducationCarouselContract.isContentSignal(payloadData) {
                analytics.trackPageViewed(.educationCarousel)
            }
        case "lrs.education_steps_failed", "lrs.education_steps_failed_to_show":
            let failure = AnalyticsEducationCarouselError(pageReason: payloadData["reason"])
            analytics.trackActionFailed(.educationCarousel(failure))
        // No second `dependencies.failed_to_load` handler. The envelope-level case already tracks
        // it; handling it here too tracked the same failure twice for one message. The page reports
        // it under its own name and the SDK keeps it that way - it used to be re-emitted as
        // `checkout.dependencies_failed`, an SDK-invented alias for a web event, which made an
        // event the page owns look like one the SDK raised. No dialog is drawn over the page's own
        // error screen and no console output is interpreted; that half was already correct.
        default:
            break
        }
    }

    @discardableResult
    private func complete(_ result: GlomoPayResult, payload: GlomoPayPayload? = nil, termination: TerminationSource? = nil) -> Bool {
        guard !terminalDelivered else { return false }
        // Set before the callback runs, so a host that re-enters cannot produce a second result.
        terminalDelivered = true
        deliverToListener { listener in
            switch result {
            case .success(let payload):
                listener.onPaymentSuccess(payload)
            case .failure:
                if let payload { listener.onPaymentFailure(payload) }
            case .userJourney(let journey):
                listener.onUserJourneyCompleted(journey)
            case .cancelled:
                listener.onPaymentTerminate(termination ?? .userDismiss)
            }
        }
        onComplete(result)
        return true
    }

    /// The listener is weak: if the host let it go, the result cannot be delivered. Report that
    /// rather than dropping a payment outcome in silence.
    private func deliverToListener(_ deliver: (GlomoPayListener) -> Void) {
        guard let listener else {
            errorReporter.capture(
                operation: "listener_unavailable",
                error: RouterError("Listener was released before a terminal result was delivered"),
                context: ["source": "bridge"]
            )
            return
        }
        deliver(listener)
    }

    private func emitError(message: String) {
        let error = SdkError(type: .unknown, message: message)
        errorReporter.capture(operation: "bridge_message", error: error, context: ["error_type": "unknown"])
        deliverToListener { $0.onSdkError([error]) }
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
