import Foundation

/// Tracks Sentry ingestion rate limits from `X-Sentry-Rate-Limits` and, for a bare 429,
/// `Retry-After`. Anything caught by an active limit is dropped, never queued: a payment flow
/// must not build a telemetry backlog inside a merchant's app.
///
/// See https://develop.sentry.dev/sdk/expected-features/rate-limiting/
final class SentryRateLimiter: @unchecked Sendable {
    /// The only data category this SDK sends. Event items are counted as `error`.
    static let errorCategory = "error"

    private static let allCategories = "__all__"
    private static let defaultBackoff: TimeInterval = 60

    private let now: () -> Date
    private let lock = NSLock()
    private var blockedUntil: [String: Date] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func isLimited(_ category: String) -> Bool {
        let current = now()
        return lock.glomoWithLock {
            isBlocked(Self.allCategories, at: current) || isBlocked(category, at: current)
        }
    }

    func update(statusCode: Int, rateLimits: String?, retryAfter: String?) {
        let current = now()
        lock.glomoWithLock {
            // A header that parses to no quota (for example ":error:organization") must not
            // swallow the 429: fall through to Retry-After, then the default back-off.
            let applied = rateLimits.map { applyRateLimits($0, at: current) } ?? 0
            if applied == 0, statusCode == 429 {
                block(Self.allCategories, for: backoff(retryAfter: retryAfter, at: current), at: current)
            }
        }
    }

    private func isBlocked(_ key: String, at date: Date) -> Bool {
        guard let until = blockedUntil[key] else { return false }
        if until > date { return true }
        blockedUntil[key] = nil
        return false
    }

    private func block(_ key: String, for duration: TimeInterval, at date: Date) {
        let until = date.addingTimeInterval(duration)
        if let existing = blockedUntil[key], existing >= until { return }
        blockedUntil[key] = until
    }

    /// Quotas are `retry_after:categories:scope[:reason[:namespaces]]`, comma separated, with
    /// categories separated by `;`. An empty category list means every category.
    /// Returns how many quotas were applied.
    @discardableResult
    private func applyRateLimits(_ header: String, at date: Date) -> Int {
        var applied = 0
        for quota in header.split(separator: ",") {
            let parts = quota.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = parts.first, let seconds = Self.seconds(String(first)) else { continue }
            let categories = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if categories.isEmpty {
                block(Self.allCategories, for: seconds, at: date)
                applied += 1
                continue
            }
            for category in categories.split(separator: ";") {
                let name = category.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty {
                    block(name, for: seconds, at: date)
                    applied += 1
                }
            }
        }
        return applied
    }

    private func backoff(retryAfter: String?, at date: Date) -> TimeInterval {
        guard let retryAfter else { return Self.defaultBackoff }
        if let seconds = Self.seconds(retryAfter) { return seconds }
        guard let retryDate = Self.httpDate(retryAfter) else { return Self.defaultBackoff }
        return max(0, retryDate.timeIntervalSince(date))
    }

    /// Sentry sends fractional seconds such as `2700.0`.
    private static func seconds(_ raw: String) -> TimeInterval? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }
}
