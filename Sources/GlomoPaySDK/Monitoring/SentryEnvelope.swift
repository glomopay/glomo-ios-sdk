import Foundation

/// Sentry's newline-delimited envelope format, restricted to the single `event` item this SDK
/// sends: an envelope header, an item header, and the event JSON, one per line.
///
/// See https://develop.sentry.dev/sdk/data-model/envelopes/
enum SentryEnvelope {
    /// Returns nil, never throws, when the event cannot be encoded. `JSONSerialization` raises an
    /// Objective-C exception for invalid input (NaN, non-JSON types), which Swift cannot catch and
    /// which would crash the merchant app, so every value is reduced to a JSON-safe form and the
    /// result is validated before it is serialised.
    static func eventEnvelope(
        event: [String: Any],
        eventID: String,
        dsn: String,
        sentAt: Date
    ) -> Data? {
        let header: [String: Any] = [
            "event_id": eventID,
            "sent_at": timestamp(sentAt),
            "dsn": dsn,
        ]
        guard
            let payload = encode(jsonSafe(event)),
            let headerLine = encode(header)
        else {
            return nil
        }
        // Relay slices each item by the declared length, so it must be the UTF-8 byte count of
        // the payload, not its character count.
        let itemHeader: [String: Any] = [
            "type": "event",
            "length": payload.count,
            "content_type": "application/json",
        ]
        guard let itemHeaderLine = encode(itemHeader) else { return nil }

        let newline = Data([0x0A])
        var envelope = Data()
        envelope.append(headerLine)
        envelope.append(newline)
        envelope.append(itemHeaderLine)
        envelope.append(newline)
        envelope.append(payload)
        envelope.append(newline)
        return envelope
    }

    /// RFC 3339 UTC timestamp with fractional seconds.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Reduces a value to what JSON can carry. Anything else is dropped rather than described, so
    /// an unexpected type can never smuggle its `description` onto the wire.
    static func jsonSafe(_ value: Any) -> Any? {
        switch value {
        case let value as String:
            return value
        case let value as NSNull:
            return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
            if CFNumberIsFloatType(value) {
                let double = value.doubleValue
                return double.isFinite ? double : nil
            }
            return value.int64Value
        case let value as [String: Any]:
            return value.reduce(into: [String: Any]()) { output, item in
                if let safe = jsonSafe(item.value) { output[item.key] = safe }
            }
        case let value as [Any]:
            return value.compactMap { jsonSafe($0) }
        default:
            return nil
        }
    }

    private static func encode(_ object: Any?) -> Data? {
        guard let object, JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
