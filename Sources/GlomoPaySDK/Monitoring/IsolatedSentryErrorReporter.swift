import Foundation

/// Reports explicitly captured SDK failures to GlomoPay's Sentry project through
/// `SentryEnvelopeClient`. Only sanitised, allow-listed context leaves the device.
///
/// No capture-site stack trace is attached. From a merchant's release build the frames are
/// unsymbolicated addresses in the merchant's binary, and GlomoPay never receives the merchant's
/// dSYMs, so they cannot be resolved. The message carries the operation and error type instead.
final class IsolatedSentryErrorReporter: SDKErrorReporting, @unchecked Sendable {
    static let maxBreadcrumbs = 30
    static let logger = "com.glomopay.sdk.ios"
    private static let allowedContextKeys: Set<String> = [
        "event_name", "error_type", "status_code", "webview_type", "source", "fallback_type",
    ]

    private let client: SentryEnvelopeClient
    private let sessionID: String
    private let orderID: String?
    private let devMode: Bool
    private let lock = NSLock()
    private var flowType: String
    private var breadcrumbs: [[String: Any]] = []

    /// `orderID` is the checkout's order (or subscription) id, the same value analytics sends as
    /// `order_id`. It is sent as the `order_id` tag because it is the key that joins a Sentry
    /// event to backend logs.
    init(
        client: SentryEnvelopeClient,
        sessionID: String,
        orderID: String? = nil,
        initialFlowType: String,
        devMode: Bool
    ) {
        self.client = client
        self.sessionID = sessionID
        self.orderID = orderID.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        self.flowType = initialFlowType
        self.devMode = devMode
    }

    func updateFlowType(_ flowType: String) {
        lock.glomoWithLock { self.flowType = flowType }
    }

    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {
        var breadcrumb: [String: Any] = [
            "timestamp": SentryEnvelope.timestamp(Date()),
            "level": "info",
            "category": AnalyticsSanitizer.text(category, limit: 80),
            "message": AnalyticsSanitizer.text(message, limit: 200),
        ]
        let safeData = safeContext(data)
        if !safeData.isEmpty { breadcrumb["data"] = safeData }
        lock.glomoWithLock {
            if breadcrumbs.count >= Self.maxBreadcrumbs { breadcrumbs.removeFirst() }
            breadcrumbs.append(breadcrumb)
        }
    }

    /// Snapshots the mutable state (flow type, breadcrumbs) now, so the event reflects the moment
    /// of the failure, and leaves sanitisation and building to the client's queue, which skips
    /// both entirely when the event is going to be dropped.
    func capture(operation: String, error: Error, context: [String: Any?]) {
        let state: (String, [[String: Any]]) = lock.glomoWithLock { (flowType, breadcrumbs) }
        let errorType = String(describing: type(of: error))
        client.capture { [self] in
            buildEvent(operation: operation, errorType: errorType, context: context, flowType: state.0, breadcrumbs: state.1)
        }
    }

    private func buildEvent(
        operation: String,
        errorType: String,
        context: [String: Any?],
        flowType: String,
        breadcrumbs: [[String: Any]]
    ) -> [String: Any] {
        let safeOperation = AnalyticsSanitizer.text(operation, limit: 80)
        var tags = [
            "sdk_source": "glomo-ios-sdk",
            "operation": safeOperation,
            "flow_type": flowType,
            "dev_mode": String(devMode),
        ]
        tags["order_id"] = orderID
        var event: [String: Any] = [
            "level": "error",
            "logger": Self.logger,
            "message": ["formatted": "\(safeOperation) failed (\(errorType))"],
            "tags": tags,
            "extra": ["session_id": sessionID].merging(safeContext(context)) { _, new in new },
        ]
        if !breadcrumbs.isEmpty {
            event["breadcrumbs"] = ["values": breadcrumbs]
        }
        return event
    }

    func flush(timeout: TimeInterval) {
        client.flush(timeout: timeout)
    }

    private func safeContext(_ context: [String: Any?]) -> [String: Any] {
        AnalyticsSanitizer.properties(context).filter { Self.allowedContextKeys.contains($0.key) }
    }
}

enum SDKErrorReporterFactory {
    static func create(
        config: GlomoPayConfig,
        sessionID: String,
        flowType: String,
        runtime: SDKTelemetryRuntime = .shared
    ) -> SDKErrorReporting {
        guard let client = runtime.sentryClient else { return NoOpSDKErrorReporter() }
        return IsolatedSentryErrorReporter(
            client: client,
            sessionID: sessionID,
            orderID: config.checkoutId,
            initialFlowType: flowType,
            devMode: SDKBuildFlags.internalBuild
        )
    }
}
