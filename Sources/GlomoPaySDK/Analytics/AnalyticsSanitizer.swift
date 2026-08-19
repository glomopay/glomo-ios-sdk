import Foundation

enum AnalyticsSanitizer {
    private static let blockedKey = makeExpression(
        pattern: "email|phone|mobile|customer_name|card|pan|account|aadhaar|passport|voter|kyc",
        options: [.caseInsensitive]
    )
    private static let patterns = [
        "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        "(?<![A-Za-z0-9_])(?:\\d[\\s-]*){6,}(?![A-Za-z0-9_])",
        "(?<![A-Za-z0-9_])[A-Z]{5}[0-9]{4}[A-Z](?![A-Za-z0-9_])",
        "(?<![A-Za-z0-9_])[A-Z][0-9]{7}(?![A-Za-z0-9_])",
        "(?<![A-Za-z0-9_])[A-Z]{3}[0-9]{7}(?![A-Za-z0-9_])",
    ].compactMap { makeExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let isoTimestamp = makeExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}(?:Z|[+-]\\d{2}:?\\d{2})$"
    )

    static func properties(_ input: [String: Any?]) -> [String: Any] {
        input.reduce(into: [String: Any]()) { output, item in
            guard !matches(blockedKey, item.key) else { return }
            guard let value = item.value else {
                output[item.key] = NSNull()
                return
            }
            if item.key == "timestamp", let timestamp = value as? String, matches(isoTimestamp, timestamp) {
                output[item.key] = timestamp
                return
            }
            if let safe = sanitize(value) { output[item.key] = safe }
        }
    }

    static func text(_ value: String, limit: Int) -> String {
        String(redact(value).prefix(limit))
    }

    static func navigationURL(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.lowercased()
        components.port = url.port
        components.path = sanitizePath(url.path)
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

    private static func sanitize(_ value: Any) -> Any? {
        switch value {
        case let value as Bool: return value
        case let value as Int: return value
        case let value as Int64: return value
        case let value as Double: return value
        case let value as Float: return value
        case let value as NSNumber: return value
        case let value as String: return text(value, limit: 1_000)
        default: return text(String(describing: value), limit: 1_000)
        }
    }

    private static func redact(_ value: String) -> String {
        patterns.reduce(value) { current, pattern in
            let range = NSRange(current.startIndex..., in: current)
            return pattern.stringByReplacingMatches(in: current, range: range, withTemplate: "[REDACTED]")
        }
    }

    private static func sanitizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { redact(String($0)) }
            .joined(separator: "/")
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
