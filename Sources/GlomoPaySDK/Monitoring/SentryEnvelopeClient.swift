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
    /// client's own `SentryDeviceContext`. A test pins this to exactly the keys
    /// `IsolatedSentryErrorReporter` builds, so adding a key on one side fails until the other
    /// agrees instead of being dropped silently here.
    static let allowedCallerKeys: Set<String> = [
        "level", "logger", "message", "tags", "extra", "breadcrumbs", "timestamp",
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
    /// Events discarded since the last send Sentry accepted: rate limited, over the in-flight
    /// bound, not encodable, or ending in a non-2xx response or a transport error. The next event
    /// to go out carries it as `extra.dropped_since_last_send`, so a quiet project can be told
    /// apart from one whose reports are being thrown away. While that event is in flight the
    /// reported number is held back; a 2xx releases it, anything else returns it to the count.
    private var droppedSinceLastSend = 0

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

    /// Returns immediately. The drop decisions (rate limit, in-flight bound) are made first, on
    /// the caller's thread and without building anything; `build` then runs on the client's
    /// utility queue, so event construction and sanitisation never cost the caller's (often the
    /// main) thread, and a dropped event is never built.
    ///
    /// `completion` is opt-in and defaults to nil: it runs once with the outcome before
    /// `flush(timeout:)` can observe the send as finished. Production callers pass none; it exists
    /// for delivery verification and tests.
    func capture(
        completion: (@Sendable (SentrySendOutcome) -> Void)? = nil,
        _ build: @escaping () -> [String: Any]
    ) {
        if rateLimiter.isLimited(SentryRateLimiter.errorCategory) {
            GlomoPayLogger.error("Sentry event dropped: rate limited")
            recordDropped(1)
            completion?(.dropped)
            return
        }
        let admitted: Bool = lock.glomoWithLock {
            guard inFlightCount < Self.maxInFlight else { return false }
            inFlightCount += 1
            return true
        }
        guard admitted else {
            GlomoPayLogger.error("Sentry event dropped: too many sends in flight")
            recordDropped(1)
            completion?(.dropped)
            return
        }
        inFlight.enter()
        queue.async { [self] in
            send(build: build, completion: completion)
        }
    }

    /// Convenience for an event that is already built.
    func capture(event: [String: Any], completion: (@Sendable (SentrySendOutcome) -> Void)? = nil) {
        capture(completion: completion) { event }
    }

    /// Waits up to `timeout` for in-flight sends to finish. Blocks the calling thread, so callers
    /// must not use it on the main thread (`SDKErrorReporterTerminalFlusher` does not).
    func flush(timeout: TimeInterval) {
        let seconds = timeout.isFinite ? max(0, timeout) : 0
        _ = inFlight.wait(timeout: .now() + seconds)
    }

    private func send(build: () -> [String: Any], completion: (@Sendable (SentrySendOutcome) -> Void)?) {
        // Checked again: a limit can arrive from another send while this one was queued.
        guard !rateLimiter.isLimited(SentryRateLimiter.errorCategory) else {
            GlomoPayLogger.error("Sentry event dropped: rate limited")
            recordDropped(1)
            finish(.dropped, completion)
            return
        }
        let reported: Int = lock.glomoWithLock {
            defer { droppedSinceLastSend = 0 }
            return droppedSinceLastSend
        }
        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sentAt = now()
        guard
            let body = SentryEnvelope.eventEnvelope(
                event: prepare(build(), eventID: eventID, timestamp: sentAt, droppedSinceLastSend: reported),
                eventID: eventID,
                dsn: dsn.value,
                sentAt: sentAt
            ),
            body.count <= Self.maxEnvelopeBytes
        else {
            GlomoPayLogger.error("Sentry event dropped: it could not be encoded")
            recordDropped(reported + 1)
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
        // The item header's `length` describes the uncompressed envelope; only the HTTP body is
        // compressed. If compression fails the envelope goes out as is.
        if let compressed = SentryGzip.compress(body) {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = compressed
        } else {
            request.httpBody = body
        }

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
                    recordDropped(reported + 1)
                }
            } else {
                GlomoPayLogger.error("Sentry event delivery failed", error: error)
                recordDropped(reported + 1)
            }
            finish(outcome, completion)
        }.resume()
    }

    /// Adds the fields `SentryClient` used to fill from its options. No `user` object, no
    /// `request` and no IP are sent. `infer_ip: never` is required, not a default: for the Cocoa
    /// platform Relay treats an unset value as `auto` and stores the connection IP, which a live
    /// event confirmed. With `never`, Sentry derives approximate location (country, region, city)
    /// at ingest and does not store the device IP. Declared as coarse location for app
    /// functionality in `PrivacyInfo.xcprivacy`.
    private func prepare(
        _ event: [String: Any],
        eventID: String,
        timestamp: Date,
        droppedSinceLastSend: Int
    ) -> [String: Any] {
        var prepared = event.filter { Self.allowedCallerKeys.contains($0.key) }
        if droppedSinceLastSend > 0 {
            var extra = prepared["extra"] as? [String: Any] ?? [:]
            extra["dropped_since_last_send"] = droppedSinceLastSend
            prepared["extra"] = extra
        }
        prepared["event_id"] = eventID
        // `timestamp` is when the failure happened, taken by the caller at capture; `sent_at` in
        // the envelope header stays the send time, and the gap is what lets Relay correct for
        // device clock skew. Only a caller that supplies none gets the send time.
        if let captured = event["timestamp"] as? Double, captured.isFinite {
            prepared["timestamp"] = captured
        } else {
            prepared["timestamp"] = timestamp.timeIntervalSince1970
        }
        prepared["platform"] = Self.platform
        prepared["environment"] = Self.environment
        prepared["release"] = Self.release
        prepared["contexts"] = contexts
        prepared["sdk"] = [
            "name": Self.sdkName,
            "version": Self.sdkVersion,
            "settings": ["infer_ip": "never"],
        ] as [String: Any]
        return prepared
    }

    private func recordDropped(_ count: Int) {
        lock.glomoWithLock { droppedSinceLastSend += count }
    }

    private func finish(_ outcome: SentrySendOutcome, _ completion: (@Sendable (SentrySendOutcome) -> Void)?) {
        completion?(outcome)
        lock.glomoWithLock { inFlightCount -= 1 }
        inFlight.leave()
    }
}
