import Foundation

/// The v1 checkout progress contract, as the checkout page sends it.
///
/// Hand-written from `checkout-events.schema.json` and `events-table.md` in the checkout monorepo.
/// That package publishes no Swift and ships no fixtures, so this is a transcription rather than a
/// generated binding - when the schema moves, this file has to be re-read against it.
///
/// `stage`, `step`, `provider`, `method` and `reason` are plain strings on purpose. The contract
/// types them as open strings so a new bank, screen or close reason reaches a merchant instead of
/// failing their validator, and an enum here would turn each of those additions into a dropped
/// event in every host already shipped. `GlomoCheckoutStages` and friends name today's values for
/// comparison; none of them is a closed set.
public enum GlomoCheckoutEventContract {
    /// The payload version this SDK understands.
    public static let version = 1
}

/// Payment-flow stages, in the order the page emits them.
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

    /// In emission order. The page only ever moves forward through these.
    public static let payment = [
        opened, methodSelected, detailsSubmitted, attemptCreated,
        customerAuth, providerHandoff, awaitingConfirmation, confirmed, failed,
    ]

    /// Reserved in the contract; the LRS checkout does not send these today.
    public static let kyc = [
        opened, "in_progress", "submitted", "under_review",
        "action_required", "approved", "rejected", "expired", "failed",
    ]
}

/// Why a checkout closed.
///
/// `merchant_closed` was dropped from the contract before it shipped, which is why a checkout
/// closed by host code reports no close event at all rather than borrowing one of these.
public enum GlomoCheckoutCloseReasons {
    public static let userDismissed = "user_dismissed"
    public static let userCancelled = "user_cancelled"
    public static let completed = "completed"
    public static let error = "error"
    public static let confirmationTimeout = "confirmation_timeout"

    /// The reason to report for a close this SDK writes itself, or nil when the contract has no
    /// honest value for it.
    ///
    /// `.programmatic` returns nil: the merchant closed the checkout, so none of the five reasons
    /// describes it, and the merchant already knows. Reporting `user_dismissed` there would blame
    /// the customer for the host's own call.
    public static func forTermination(_ source: TerminationSource) -> String? {
        switch source {
        case .userDismiss: return userDismissed
        case .connectionError: return error
        case .programmatic: return nil
        }
    }
}

/// What the checkout is for. On LRS this is always the order.
public struct GlomoCheckoutResource: Equatable {
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

/// Position within a multi-part step, where the page reports one. 1-based.
public struct GlomoCheckoutSegment: Equatable {
    public let index: Int
    public let total: Int

    public init(index: Int, total: Int) {
        self.index = index
        self.total = total
    }

    /// Dropped rather than half-built: a segment missing a bound says nothing useful.
    init?(json: Any?) {
        guard let data = json as? [String: Any],
              let index = data["index"] as? Int,
              let total = data["total"] as? Int
        else { return nil }
        self.init(index: index, total: total)
    }
}

/// The customer reached a new stage, or a new step within the current stage.
///
/// Every field is relayed from the page; the SDK derives none of them. Stages arrive in order and
/// never repeat, so a drop-off funnel can be built by appending.
///
/// `rawPayload` carries the payload exactly as it arrived, including any field added to the
/// contract after this SDK was built. Read it when a value you need has no typed property yet.
public struct GlomoCheckoutStageChangedEvent: Equatable {
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

    /// Parses leniently and never fails.
    ///
    /// A payload that violates the contract is still delivered, with missing strings read as empty:
    /// a merchant comparing this against the web SDK should see one contract, and the web SDK
    /// forwards contract-violating payloads unchanged. `rawPayload` is always the authority on what
    /// actually arrived.
    public init(json: [String: Any]) {
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

/// The checkout closed, with the furthest point it reached.
///
/// Delivered at most once per checkout. `lastStage` is absent when the checkout closed before it
/// finished opening - so an absent value is a claim in its own right, not merely a missing field.
public struct GlomoCheckoutClosedEvent: Equatable {
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

    /// Parses leniently and never fails, for the same reason as the stage event above.
    public init(json: [String: Any]) {
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
    /// Whether this is a stage the SDK can quote back in a close it writes itself.
    ///
    /// An unrecognised stage is not an error - it was already forwarded to the merchant - it just
    /// cannot become the SDK's own claim about where the customer stopped.
    var isRecognised: Bool {
        guard version == GlomoCheckoutEventContract.version else { return false }
        guard !journeyId.isEmpty, !resource.id.isEmpty else { return false }
        // An absent or unrecognised flow reads as the payment flow: LRS is the only flow that
        // ships, and the two stage sets overlap only on values meaning the same thing in both.
        let known = flow == "kyc" ? GlomoCheckoutStages.kyc : GlomoCheckoutStages.payment
        return known.contains(stage)
    }

    /// The close the SDK writes when the customer leaves without the page getting to say so.
    ///
    /// Everything except `reason` and `at` is copied from this stage change rather than
    /// reconstructed, so the event reconciles against the stage events the merchant already
    /// received. `at` is the moment of the close, not of the stage change.
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

private extension [String: Any] {
    /// Absent and empty are the same thing to a consumer, and the contract gives every optional
    /// string a minimum length - so an empty one is read as absent rather than carried through.
    func nonEmptyString(_ key: String) -> String? {
        (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func hashableValues() -> [String: AnyHashable] {
        reduce(into: [String: AnyHashable]()) { result, item in
            if let value = item.value as? AnyHashable { result[item.key] = value }
        }
    }
}
