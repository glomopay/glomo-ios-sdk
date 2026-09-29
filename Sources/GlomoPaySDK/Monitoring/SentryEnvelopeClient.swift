import Foundation

/// Minimal Sentry ingestion client speaking the envelope protocol over `URLSession`.
///
/// It replaces a private `SentryClient` from sentry-cocoa. Shipping a Sentry SDK inside a library
/// is discouraged by Sentry itself (version conflicts with the host app's own Sentry, PII
/// leakage), and SwiftPM resolves one version per package for the whole app graph, so pinning
/// sentry-cocoa made the SDK uninstallable next to any other Sentry version.
///
/// Deliberately not an SDK: it installs no crash or exception handlers, swizzles nothing, keeps
/// no global scope, and writes nothing to disk. It only POSTs events GlomoPay code hands it.
/// Every failure is swallowed; telemetry must never throw into, block, or crash checkout.
final class SentryEnvelopeClient: @unchecked Sendable {
    /// Kept identical to what the sentry-cocoa 9.19.1 client reported, so Sentry-side issue
    /// search, alert rules and dashboards filtering on `sdk.name` or `platform` keep matching.
    /// The version is frozen at the last sentry-cocoa release this SDK shipped.
    static let sdkName = "sentry.cocoa"
    static let sdkVersion = "9.19.1"
    static let platform = "cocoa"
    /// sentry-cocoa's default environment, which the previous client never overrode.
    static let environment = "production"
    /// Bounded, so a stalled network can never hold a checkout's telemetry for long. Matches the
    /// Mixpanel transport.
    static let requestTimeout: TimeInterval = 10
    /// Beyond this many concurrent sends, new events are dropped rather than queued.
    static let maxInFlight = 8
    /// Sentry rejects larger events; refusing them locally avoids a pointless upload.
    static let maxEnvelopeBytes = 512 * 1_024

    /// Only these top-level event keys are sent. Anything else a caller adds, notably `user`,
    /// `request`, `contexts` or `server_name`, never reaches the wire.
    private static let allowedCallerKeys: Set<String> = [
        "level", "logger", "message", "tags", "extra", "breadcrumbs",
    ]

    let dsn: SentryDSN
    private let session: URLSession
    private let rateLimiter: SentryRateLimiter
    private let now: () -> Date
    private let release: String?
    private let dist: String?
    private let queue = DispatchQueue(label: "com.glomopay.sdk.sentry", qos: .utility)
    private let inFlight = DispatchGroup()
    private let lock = NSLock()
    private var inFlightCount = 0

    /// Returns nil for a blank or malformed DSN, which callers treat as "error reporting off",
    /// mirroring `SentryClient(options:)` returning nil.
    init?(
        dsn rawDSN: String,
        sessionConfiguration: URLSessionConfiguration = SentryEnvelopeClient.defaultSessionConfiguration(),
        now: @escaping () -> Date = Date.init,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        guard let dsn = SentryDSN(rawDSN) else {
            GlomoPayLogger.error("Isolated Sentry client initialization failed: the DSN is blank or malformed")
            return nil
        }
        self.dsn = dsn
        self.session = URLSession(configuration: sessionConfiguration)
        self.now = now
        self.rateLimiter = SentryRateLimiter(now: now)
        self.release = Self.release(from: infoDictionary)
        self.dist = infoDictionary?["CFBundleVersion"] as? String
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Ephemeral: no cookies, no URL cache, no credential storage, nothing persisted in the host
    /// app's containers.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Returns immediately. Encoding and delivery happen on a private utility queue.
    func capture(event: [String: Any]) {
        let admitted: Bool = lock.glomoWithLock {
            guard inFlightCount < Self.maxInFlight else { return false }
            inFlightCount += 1
            return true
        }
        guard admitted else {
            GlomoPayLogger.error("Sentry event dropped: too many sends in flight")
            return
        }
        inFlight.enter()
        queue.async { [self] in
            send(event: event)
        }
    }

    /// Waits up to `timeout` for in-flight sends to finish. Blocks the calling thread, so callers
    /// must not use it on the main thread (`SDKErrorReporterTerminalFlusher` does not).
    func flush(timeout: TimeInterval) {
        let seconds = timeout.isFinite ? max(0, timeout) : 0
        _ = inFlight.wait(timeout: .now() + seconds)
    }

    private func send(event: [String: Any]) {
        guard !rateLimiter.isLimited(SentryRateLimiter.errorCategory) else {
            GlomoPayLogger.error("Sentry event dropped: rate limited")
            finish()
            return
        }
        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sentAt = now()
        guard
            let body = SentryEnvelope.eventEnvelope(
                event: prepare(event, eventID: eventID, timestamp: sentAt),
                eventID: eventID,
                dsn: dsn.value,
                sentAt: sentAt
            ),
            body.count <= Self.maxEnvelopeBytes
        else {
            GlomoPayLogger.error("Sentry event dropped: it could not be encoded")
            finish()
            return
        }

        let client = "\(Self.sdkName)/\(Self.sdkVersion)"
        var request = URLRequest(
            url: dsn.envelopeURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(dsn.authHeader(client: client), forHTTPHeaderField: "X-Sentry-Auth")
        request.setValue(client, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        session.dataTask(with: request) { [self] _, response, error in
            if let response = response as? HTTPURLResponse {
                rateLimiter.update(
                    statusCode: response.statusCode,
                    rateLimits: response.value(forHTTPHeaderField: "X-Sentry-Rate-Limits"),
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
                if !(200..<300).contains(response.statusCode) {
                    GlomoPayLogger.error("Sentry rejected an event with status \(response.statusCode)")
                }
            } else if let error {
                GlomoPayLogger.error("Sentry event delivery failed", error: error)
            }
            finish()
        }.resume()
    }

    /// Adds the fields `SentryClient` used to fill from its options. The previous client sent no
    /// `user`, no `request` and no IP; `infer_ip: never` stops Sentry deriving one from the
    /// connection, which it otherwise does by default for the Cocoa platform.
    private func prepare(_ event: [String: Any], eventID: String, timestamp: Date) -> [String: Any] {
        var prepared = event.filter { Self.allowedCallerKeys.contains($0.key) }
        prepared["event_id"] = eventID
        prepared["timestamp"] = timestamp.timeIntervalSince1970
        prepared["platform"] = Self.platform
        prepared["environment"] = Self.environment
        prepared["release"] = release
        prepared["dist"] = dist
        prepared["sdk"] = [
            "name": Self.sdkName,
            "version": Self.sdkVersion,
            "settings": ["infer_ip": "never"],
        ] as [String: Any]
        return prepared
    }

    private func finish() {
        lock.glomoWithLock { inFlightCount -= 1 }
        inFlight.leave()
    }

    /// sentry-cocoa's default release: the host app's `bundleId@version+build`.
    private static func release(from infoDictionary: [String: Any]?) -> String? {
        guard let infoDictionary else { return nil }
        let identifier = infoDictionary["CFBundleIdentifier"] as? String ?? ""
        let version = infoDictionary["CFBundleShortVersionString"] as? String ?? ""
        let build = infoDictionary["CFBundleVersion"] as? String ?? ""
        return "\(identifier)@\(version)+\(build)"
    }
}
