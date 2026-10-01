import Foundation

/// A non-payment journey the customer completed inside checkout.
///
/// One member, on purpose. The RN SDK's equivalent carries a second member for the pay-via-bank
/// (lean/open finance) flow. That flow is sunset and was never supported here, so it is
/// deliberately absent - a member a host can receive but never see is a question every
/// integration has to ask us about once. This matches Flutter and diverges from RN knowingly.
///
/// Append new members; never insert. Hosts and stored records key off the raw value.
public enum GlomoPayUserJourneyType: String, Sendable, CaseIterable {
    case bankTransferSubmitted = "bank_transfer_submitted"
}

/// Deliberately not a `GlomoPayPayload`.
///
/// That type's `paymentId` and `signature` are the fields a host verifies a payment with, and
/// neither exists for a journey: no money has moved. Reusing it invited exactly the signature
/// check that can never pass, which is how a submitted bank transfer came to be reported as a
/// completed payment.
public struct GlomoPayUserJourneyPayload: Sendable, Equatable {
    public let journeyType: GlomoPayUserJourneyType
    public let orderId: String
    public let senderAccountNumber: String?
    public let transactionReference: String?
    public let status: String?
    public let rawResponse: [String: AnyHashable]?

    public init(
        journeyType: GlomoPayUserJourneyType,
        orderId: String,
        senderAccountNumber: String? = nil,
        transactionReference: String? = nil,
        status: String? = nil,
        rawResponse: [String: AnyHashable]? = nil
    ) {
        self.journeyType = journeyType
        self.orderId = orderId
        self.senderAccountNumber = senderAccountNumber
        self.transactionReference = transactionReference
        self.status = status
        self.rawResponse = rawResponse
    }

    /// Fields are read coercively, in both camelCase and snake_case, because the page has sent
    /// both. A cast would throw inside the delivery path after the one-result latch is spent,
    /// losing the transfer entirely. This extends the `as?`-with-snake_case-fallback style
    /// `GlomoPayPayload(json:)` already uses rather than inventing a second one.
    public init(journeyType: GlomoPayUserJourneyType, json: [String: Any]) {
        let nested = json["payload"] as? [String: Any]
        let data = nested.map { json.merging($0) { _, nestedValue in nestedValue } } ?? json
        self.init(
            journeyType: journeyType,
            orderId: Self.read(data, "orderId", "order_id") ?? "",
            senderAccountNumber: Self.read(data, "senderAccountNumber", "sender_account_number"),
            transactionReference: Self.read(data, "transactionReference", "transaction_reference"),
            status: Self.read(data, "status", "status"),
            rawResponse: json.reduce(into: [String: AnyHashable]()) { result, item in
                if let value = item.value as? AnyHashable { result[item.key] = value }
            }
        )
    }

    /// Coercing: the page has sent these as numbers as well as strings.
    private static func read(_ json: [String: Any], _ camelCase: String, _ snakeCase: String) -> String? {
        let raw = json[camelCase] ?? json[snakeCase]
        guard let raw, !(raw is NSNull) else { return nil }
        let value = String(describing: raw)
        return value.isEmpty ? nil : value
    }
}
