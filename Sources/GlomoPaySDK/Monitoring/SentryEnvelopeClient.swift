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
/// What happened to one captured event.
enum SentrySendOutcome: Equatable, Sendable {
    /// Sentry answered with an HTTP status, successful or not.
    case responded(eventID: String, statusCode: Int)
    /// The request failed in transport and was not retried.
    case failed(eventID: String)
    /// Never sent: rate limited, over the in-flight bound, or not encodable.
    case dropped
}

final class SentryEnvelopeClient: @unchecked Sendable {
    /// The SDK identifies as itself, not as sentry-cocoa, matching Android's
    /// `glomo-android-sdk/<version>`. Sent as `sdk.name`/`sdk.version`, `sentry_client` and
    /// `User-Agent`.
    static let sdkName = "glomo-ios-sdk"
    static let sdkVersion = GlomoPaySDKBuild.version
    static let platform = "cocoa"
    /// Matches Android (`glomo-android-sdk@<version>`, environment `glomo-android-sdk`): Sentry
    /// releases track the SDK version, not the host app's. The host app's version and build are
    /// only in `contexts.app`, and its bundle id is not sent at all.
    static let release = "\(sdkName)@\(sdkVersion)"
    static let environment = sdkName
    /// Bounded, so a stalled network can never hold a checkout's telemetry for long. Matches the
    /// Mixpanel transport.
    static let requestTimeout: TimeInterval = 10
    /// Beyond this many concurrent sends, new events are dropped rather than queued.
    static let maxInFlight = 8
    /// Sentry rejects larger events; refusing them locally avoids a pointless upload.
    static let maxEnvelopeBytes = 512 * 1_024

    /// Only these top-level event keys are accepted from callers. Anything else, notably `user`,
    /// `request`, `contexts` or `server_name`, never reaches the wire; `contexts` is only ever the
    /// client's own `SentryDeviceContext`.
    private static let allowedCallerKeys: Set<String> = [
        "level", "logger", "message", "tags", "extra", "breadcrumbs",
    ]

    let dsn: SentryDSN
    private let session: URLSession
    private let rateLimiter: SentryRateLimiter
    private let now: () -> Date
    private let contexts: [String: Any]
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
        self.contexts = SentryDeviceContext.make(infoDictionary: infoDictionary)
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
    /// `completion`, if given, runs once with the outcome before `flush(timeout:)` can observe the
    /// send as finished. Production callers pass none; it exists for delivery verification.
    func capture(event: [String: Any], completion: (@Sendable (SentrySendOutcome) -> Void)? = nil) {
        let admitted: Bool = lock.glomoWithLock {
            guard inFlightCount < Self.maxInFlight else { return false }
            inFlightCount += 1
            return true
        }
        guard admitted else {
            GlomoPayLogger.error("Sentry event dropped: too many sends in flight")
            completion?(.dropped)
            return
        }
        inFlight.enter()
        queue.async { [self] in
            send(event: event, completion: completion)
        }
    }

    /// Waits up to `timeout` for in-flight sends to finish. Blocks the calling thread, so callers
    /// must not use it on the main thread (`SDKErrorReporterTerminalFlusher` does not).
    func flush(timeout: TimeInterval) {
        let seconds = timeout.isFinite ? max(0, timeout) : 0
        _ = inFlight.wait(timeout: .now() + seconds)
    }

    private func send(event: [String: Any], completion: (@Sendable (SentrySendOutcome) -> Void)?) {
        guard !rateLimiter.isLimited(SentryRateLimiter.errorCategory) else {
            GlomoPayLogger.error("Sentry event dropped: rate limited")
            finish(.dropped, completion)
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
            finish(.dropped, completion)
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
            var outcome = SentrySendOutcome.failed(eventID: eventID)
            if let response = response as? HTTPURLResponse {
                outcome = .responded(eventID: eventID, statusCode: response.statusCode)
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
            finish(outcome, completion)
        }.resume()
    }

    /// Adds the fields `SentryClient` used to fill from its options. No `user` object and no
    /// `request` are sent. `infer_ip: auto` asks Sentry to store the connection's public IP as
    /// `user.ip_address` and derive geo from it, for correlation with backend and edge logs;
    /// declared as coarse location for app functionality in `PrivacyInfo.xcprivacy`.
    private func prepare(_ event: [String: Any], eventID: String, timestamp: Date) -> [String: Any] {
        var prepared = event.filter { Self.allowedCallerKeys.contains($0.key) }
        prepared["event_id"] = eventID
        prepared["timestamp"] = timestamp.timeIntervalSince1970
        prepared["platform"] = Self.platform
        prepared["environment"] = Self.environment
        prepared["release"] = Self.release
        prepared["contexts"] = contexts
        prepared["sdk"] = [
            "name": Self.sdkName,
            "version": Self.sdkVersion,
            "settings": ["infer_ip": "auto"],
        ] as [String: Any]
        return prepared
    }

    private func finish(_ outcome: SentrySendOutcome, _ completion: (@Sendable (SentrySendOutcome) -> Void)?) {
        completion?(outcome)
        lock.glomoWithLock { inFlightCount -= 1 }
        inFlight.leave()
    }
}
