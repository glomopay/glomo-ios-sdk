import Foundation

enum AnalyticsSanitizer {
    static let valueLimit = 1_000

    private static let identifierKeys: Set<String> = [
        "journey_id",
        "$insert_id",
        "distinct_id",
        "$device_id",
        "resource_id",
    ]
    /// Device and host-app metadata whose formats the SDK does not control - a host
    /// app's version can legitimately be `1.4.0-20261001` - and which cannot carry customer data.
    /// These keep exactly the treatment they had before free-text redaction reached strings
    /// (whole-value checks, then the length cap), so redaction cannot rewrite them.
    private static let metadataKeys: Set<String> = [
        "$app_version_string", "$app_build_number", "$app_namespace", "$app_name",
        "$model", "$device", "$os", "$os_version", "$manufacturer", "$brand",
        "$device_type", "$locale", "$lib_version", "mp_lib",
    ]
    private static let sensitiveKeyTokens: Set<String> = [
        "email", "phone", "mobile", "pan", "aadhaar", "name", "account", "card", "address", "dob",
        "token", "otp", "passport", "voter",
    ]
    private static let exemptKeys: Set<String> = [
        "page_name", "cta_name", "action_name", "control_name", "error_code", "error_detail",
        "trigger", "status", "webview_type", "permission", "request_source", "last_step",
        "page_event", "payment_event", "api_path", "integration", "platform", "journey",
        "key_mode", "dev_mode", "step_name", "otp_channel", "failure_reason",
    ]
    private static let boundedDigits = "(?<![A-Za-z0-9_])(?:\\d[ -]?){%d,%d}\\d(?![A-Za-z0-9_])"
    private static let valueRules: [(expression: NSRegularExpression?, mask: (String) -> String?)] = [
        (makeExpression(pattern: String(format: boundedDigits, 12, 18)), maskCard),
        (makeExpression(pattern: String(format: boundedDigits, 9, 11)), maskDigits),
        (
            makeExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive]),
            maskEmail
        ),
        (
            makeExpression(
                pattern: "(?<![A-Za-z0-9_])[A-Z]{5}[0-9]{4}[A-Z](?![A-Za-z0-9_])",
                options: [.caseInsensitive]
            ),
            maskTaxPAN
        ),
        (
            makeExpression(
                pattern: "(?<![A-Za-z0-9_])(?:[A-Z]{3}[0-9]{7}|[A-Z][0-9]{7})(?![A-Za-z0-9_])",
                options: [.caseInsensitive]
            ),
            { _ in "•••" }
        ),
    ]
    private static let uuidValue = makeExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
        options: [.caseInsensitive]
    )
    static func properties(_ input: [String: Any?]) -> [String: Any] {
        input.reduce(into: [String: Any]()) { output, item in
            guard let value = item.value, !(value is NSNull) else {
                output[item.key] = NSNull()
                return
            }
            if identifierKeys.contains(item.key) {
                if let safe = sanitizeIdentifier(value) { output[item.key] = safe }
                return
            }
            if metadataKeys.contains(item.key), let string = value as? String {
                output[item.key] = String(string.prefix(valueLimit))
                return
            }
            guard let scalar = scalar(value) else { return }
            if !(scalar is Bool), isSensitiveKey(item.key) {
                output[item.key] = maskSensitiveValue(scalar, key: item.key)
                return
            }
            if let string = scalar as? String {
                output[item.key] = String(maskValues(in: string).prefix(valueLimit))
                return
            }
            output[item.key] = scalar
        }
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = snakeCase(key)
        guard !normalized.hasPrefix("$"), !exemptKeys.contains(normalized) else { return false }
        return tokens(of: normalized).contains { sensitiveKeyTokens.contains($0) }
    }

    private static func tokens(of key: String) -> [String] {
        snakeCase(key).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func maskValues(in value: String) -> String {
        if matches(uuidValue, value) { return value }
        return valueRules.reduce(value) { current, rule in
            replaceMatches(of: rule.expression, in: current, using: rule.mask)
        }
    }

    static func urlOrigin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.lowercased()
        components.port = url.port
        return components.url?.absoluteString
    }

    static func bankRedirectURL(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.lowercased()
        return components.url?.absoluteString
    }

    private static func scalar(_ value: Any) -> Any? {
        switch value {
        case let value as NSNumber where isBooleanNumber(value): return value.boolValue
        case let value as Int: return value
        case let value as Int64: return value
        case let value as Double: return value
        case let value as Float: return value
        case let value as NSNumber: return sanitizeNumber(value)
        case let value as Bool: return value
        case let value as String: return value
        default: return nil
        }
    }

    private static func sanitizeIdentifier(_ value: Any) -> Any? {
        switch value {
        case let value as String: return String(value.prefix(valueLimit))
        case let value as NSNumber where isBooleanNumber(value): return value.boolValue
        case let value as Int: return value
        case let value as Int64: return value
        case let value as Double: return value
        case let value as Float: return value
        case let value as NSNumber: return sanitizeNumber(value)
        case let value as Bool: return value
        default: return nil
        }
    }

    private static func maskSensitiveValue(_ value: Any, key: String) -> String {
        let digits = (value as? String ?? "\(value)").filter(\.isNumber)
        guard tokens(of: key).contains("account"), digits.count >= 4 else { return "•••" }
        return "••••\(digits.suffix(4))"
    }

    private static func maskCard(_ match: String) -> String? {
        let digits = match.filter(\.isNumber)
        guard passesLuhn(digits) else { return nil }
        return "XXXX-XXXX-XXXX-\(digits.suffix(4))"
    }

    private static func maskDigits(_ match: String) -> String? {
        "••••\(match.filter(\.isNumber).suffix(4))"
    }

    private static func maskEmail(_ match: String) -> String? {
        guard let at = match.firstIndex(of: "@"), let first = match.first else { return nil }
        return "\(first)•••\(match[at...])"
    }

    private static func maskTaxPAN(_ match: String) -> String? {
        "XXXXXX\(match.suffix(4))"
    }

    private static func passesLuhn(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, !values.isEmpty else { return false }
        let sum = values.reversed().enumerated().reduce(0) { total, item in
            guard item.offset % 2 == 1 else { return total + item.element }
            let doubled = item.element * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    private static func replaceMatches(
        of expression: NSRegularExpression?,
        in value: String,
        using mask: (String) -> String?
    ) -> String {
        guard let expression else { return value }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var output = value
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output), let masked = mask(String(output[range])) else {
                continue
            }
            output.replaceSubrange(range, with: masked)
        }
        return output
    }

    private static func snakeCase(_ key: String) -> String {
        var output = ""
        var previous: Character?
        for character in key {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                output.append("_")
            }
            output.append(contentsOf: character.lowercased())
            previous = character
        }
        return output
    }

    private static func sanitizeNumber(_ value: NSNumber) -> Any {
        if CFNumberIsFloatType(value) {
            return value.doubleValue
        }
        return value.int64Value
    }

    private static func isBooleanNumber(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func makeExpression(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            GlomoPayLogger.error("Analytics sanitizer pattern could not be compiled", error: error)
            return try? NSRegularExpression(pattern: "(?!)")
        }
    }

    private static func matches(_ expression: NSRegularExpression?, _ value: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
