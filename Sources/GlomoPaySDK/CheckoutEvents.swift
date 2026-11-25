import Foundation

/// v1 checkout progress contract, hand-transcribed from `checkout-events.schema.json` in the
/// checkout monorepo; keep in sync with it. `stage`, `step`, `provider`, `method` and `reason`
/// are open strings: an enum would drop new values in hosts already shipped.
enum GlomoCheckoutEventContract {
    static let version = 1
}

public enum GlomoCheckoutStages {
    public static let opened = "opened"
    public static let methodSelected = "method_selected"
    public static let detailsSubmitted = "details_submitted"
    public static let attemptCreated = "attempt_created"
    public static let customerAuth = "customer_auth"
    public static let providerHandoff = "provider_handoff"
    public static let awaitingConfirmation = "awaiting_confirmation"
    public static let confirmed = "confirmed"
    public static let failed = "failed"

    /// The page only moves forward through these.
    static let payment = [
        opened, methodSelected, detailsSubmitted, attemptCreated,
        customerAuth, providerHandoff, awaitingConfirmation, confirmed, failed,
    ]

    /// Reserved in the contract; the LRS checkout does not send these.
    static let kyc = [
        opened, "in_progress", "submitted", "under_review",
        "action_required", "approved", "rejected", "expired", "failed",
    ]
}

public enum GlomoCheckoutCloseReasons {
    public static let userDismissed = "user_dismissed"
    public static let userCancelled = "user_cancelled"
    public static let completed = "completed"
    public static let error = "error"
    public static let confirmationTimeout = "confirmation_timeout"

    /// The reason to report for a close this SDK writes itself, or nil when the contract has no
    /// honest value for it.
    ///
    /// `.programmatic` returns nil: the merchant closed the checkout, so `user_dismissed` would
    /// blame the customer. A delivered outcome outranks the rest - the journey ended in a result,
    /// and the dismissal is only the customer leaving the screen that said so.
    static func forClose(
        source: TerminationSource,
        outcome: CheckoutOutcome?,
        lastStage: String?
    ) -> String? {
        if source == .programmatic { return nil }
        switch outcome {
        // Submitted, not settled - but the customer finished what the checkout asked of them,
        // and the contract has no separate reason for it.
        case .succeeded, .journeySubmitted: return completed
        case .failed: return error
        case nil: break
        }
        if source == .connectionError { return error }
        switch lastStage {
        case GlomoCheckoutStages.confirmed: return completed
        case GlomoCheckoutStages.failed: return error
        default: return userDismissed
        }
    }
}

/// How the journey ended, where it ended at all.
enum CheckoutOutcome {
    case succeeded
    case failed
    case journeySubmitted
}

public struct GlomoCheckoutResource: Equatable, Sendable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    init(json: Any?) {
        let data = json as? [String: Any]
        self.init(
            type: data?["type"] as? String ?? "",
            id: data?["id"] as? String ?? ""
        )
    }
}

/// 1-based position within a multi-part step.
public struct GlomoCheckoutSegment: Equatable, Sendable {
    public let index: Int
    public let total: Int

    public init(index: Int, total: Int) {
        self.index = index
        self.total = total
    }

    init?(json: Any?) {
        guard let data = json as? [String: Any],
              let index = data["index"] as? Int,
              let total = data["total"] as? Int
        else { return nil }
        self.init(index: index, total: total)
    }
}

/// Stages arrive in order; each stage and step pair arrives at most once. `rawPayload` holds
/// the payload as received, including fields newer than this SDK.
///
/// `@unchecked Sendable`: every stored property is a `let`, and `rawPayload` is built from
/// `JSONSerialization` output, whose values are immutable Foundation types.
public struct GlomoCheckoutStageChangedEvent: Equatable, @unchecked Sendable {
    public let version: Int
    public let resource: GlomoCheckoutResource
    public let journeyId: String
    public let at: String
    public let flow: String
    public let stage: String
    public let method: String?
    public let paymentId: String?
    public let step: String?
    public let provider: String?
    public let journeyType: String?
    public let errorCode: String?
    public let segment: GlomoCheckoutSegment?
    public let rawPayload: [String: AnyHashable]?

    public init(
        version: Int,
        resource: GlomoCheckoutResource,
        journeyId: String,
        at: String,
        flow: String,
        stage: String,
        method: String? = nil,
        paymentId: String? = nil,
        step: String? = nil,
        provider: String? = nil,
        journeyType: String? = nil,
        errorCode: String? = nil,
        segment: GlomoCheckoutSegment? = nil,
        rawPayload: [String: AnyHashable]? = nil
    ) {
        self.version = version
        self.resource = resource
        self.journeyId = journeyId
        self.at = at
        self.flow = flow
        self.stage = stage
        self.method = method
        self.paymentId = paymentId
        self.step = step
        self.provider = provider
        self.journeyType = journeyType
        self.errorCode = errorCode
        self.segment = segment
        self.rawPayload = rawPayload
    }

    /// Lenient like the web SDK: a contract-violating payload is delivered, missing strings empty.
    init(json: [String: Any]) {
        self.init(
            version: json["v"] as? Int ?? 0,
            resource: GlomoCheckoutResource(json: json["resource"]),
            journeyId: json["journeyId"] as? String ?? "",
            at: json["at"] as? String ?? "",
            flow: json["flow"] as? String ?? "",
            stage: json["stage"] as? String ?? "",
            method: json.nonEmptyString("method"),
            paymentId: json.nonEmptyString("paymentId"),
            step: json.nonEmptyString("step"),
            provider: json.nonEmptyString("provider"),
            journeyType: json.nonEmptyString("journeyType"),
            errorCode: json.nonEmptyString("errorCode"),
            segment: GlomoCheckoutSegment(json: json["segment"]),
            rawPayload: json.hashableValues()
        )
    }
}

/// An absent `lastStage` means the checkout closed before it opened.
///
/// `@unchecked Sendable` for the same reason as `GlomoCheckoutStageChangedEvent`.
public struct GlomoCheckoutClosedEvent: Equatable, @unchecked Sendable {
    public let version: Int
    public let resource: GlomoCheckoutResource
    public let journeyId: String
    public let at: String
    public let flow: String
    public let reason: String
    public let method: String?
    public let paymentId: String?
    public let lastStage: String?
    public let lastStep: String?
    public let rawPayload: [String: AnyHashable]?

    public init(
        version: Int,
        resource: GlomoCheckoutResource,
        journeyId: String,
        at: String,
        flow: String,
        reason: String,
        method: String? = nil,
        paymentId: String? = nil,
        lastStage: String? = nil,
        lastStep: String? = nil,
        rawPayload: [String: AnyHashable]? = nil
    ) {
        self.version = version
        self.resource = resource
        self.journeyId = journeyId
        self.at = at
        self.flow = flow
        self.reason = reason
        self.method = method
        self.paymentId = paymentId
        self.lastStage = lastStage
        self.lastStep = lastStep
        self.rawPayload = rawPayload
    }

    init(json: [String: Any]) {
        self.init(
            version: json["v"] as? Int ?? 0,
            resource: GlomoCheckoutResource(json: json["resource"]),
            journeyId: json["journeyId"] as? String ?? "",
            at: json["at"] as? String ?? "",
            flow: json["flow"] as? String ?? "",
            reason: json["reason"] as? String ?? "",
            method: json.nonEmptyString("method"),
            paymentId: json.nonEmptyString("paymentId"),
            lastStage: json.nonEmptyString("lastStage"),
            lastStep: json.nonEmptyString("lastStep"),
            rawPayload: json.hashableValues()
        )
    }
}

extension GlomoCheckoutStageChangedEvent {
    /// Whether the SDK may quote this stage in a close it writes itself.
    var isRecognised: Bool {
        guard version == GlomoCheckoutEventContract.version else { return false }
        guard !journeyId.isEmpty, !resource.id.isEmpty else { return false }
        // Unknown flows fall back to payment; the two sets only share values meaning the same.
        let known = flow == "kyc" ? GlomoCheckoutStages.kyc : GlomoCheckoutStages.payment
        return known.contains(stage)
    }

    func synthesisedClose(reason: String, at closedAt: String) -> GlomoCheckoutClosedEvent {
        GlomoCheckoutClosedEvent(
            version: version,
            resource: resource,
            journeyId: journeyId,
            at: closedAt,
            flow: flow,
            reason: reason,
            method: method,
            paymentId: paymentId,
            lastStage: stage,
            lastStep: step
        )
    }
}

/// Whether a payload may be delivered at all.
///
/// No payload is the switch-off path and `[:]` is what arrives when the flag drops mid-session;
/// neither can become a typed event without inventing fields, and a payload stamped with another
/// contract version is not ours to read.
func isDeliverableCheckoutPayload(_ payload: [String: Any]?) -> Bool {
    guard let payload, !payload.isEmpty else { return false }
    return payload["v"] as? Int == GlomoCheckoutEventContract.version
}

private extension [String: Any] {
    /// The contract gives optional strings a minimum length, so empty reads as absent.
    func nonEmptyString(_ key: String) -> String? {
        (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func hashableValues() -> [String: AnyHashable] {
        reduce(into: [String: AnyHashable]()) { result, item in
            if let value = item.value as? AnyHashable { result[item.key] = value }
        }
    }
}
