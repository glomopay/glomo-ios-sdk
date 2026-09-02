import Foundation
import Sentry

final class IsolatedSentryClient: @unchecked Sendable {
    private let client: SentryClient?

    init(dsn: String) {
        let options = Options()
        options.dsn = dsn
        options.debug = false
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableSwizzling = false
        options.tracesSampleRate = 0
        let client = SentryClient(options: options)
        if client == nil {
            GlomoPayLogger.error(
                "Isolated Sentry client initialization failed",
                error: IsolatedSentryInitializationError.invalidConfiguration
            )
        }
        self.client = client
    }

    func capture(event: Event) {
        _ = client?.capture(event: event)
    }

    func flush(timeout: TimeInterval) {
        client?.flush(timeout: timeout)
    }
}

private enum IsolatedSentryInitializationError: LocalizedError {
    case invalidConfiguration

    var errorDescription: String? {
        "SentryClient(options:) returned nil; verify the SDK telemetry configuration"
    }
}

final class IsolatedSentryErrorReporter: SDKErrorReporting, @unchecked Sendable {
    private let client: IsolatedSentryClient
    private let sessionID: String
    private let devMode: Bool
    private let lock = NSLock()
    private var flowType: String
    private var breadcrumbs: [Breadcrumb] = []

    init(client: IsolatedSentryClient, sessionID: String, initialFlowType: String, devMode: Bool) {
        self.client = client
        self.sessionID = sessionID
        self.flowType = initialFlowType
        self.devMode = devMode
    }

    func updateFlowType(_ flowType: String) {
        lock.lock()
        self.flowType = flowType
        lock.unlock()
    }

    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {
        let breadcrumb = Breadcrumb(level: .info, category: AnalyticsSanitizer.text(category, limit: 80))
        breadcrumb.message = AnalyticsSanitizer.text(message, limit: 200)
        breadcrumb.data = safeContext(data)
        lock.lock()
        if breadcrumbs.count >= 30 { breadcrumbs.removeFirst() }
        breadcrumbs.append(breadcrumb)
        lock.unlock()
    }

    func capture(operation: String, error: Error, context: [String: Any?]) {
        let state: (String, [Breadcrumb]) = lock.withLock { (flowType, breadcrumbs) }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "\(AnalyticsSanitizer.text(operation, limit: 80)) failed (\(type(of: error)))")
        event.logger = "com.glomopay.sdk.ios"
        event.tags = [
            "sdk_source": "glomo-ios-sdk",
            "operation": AnalyticsSanitizer.text(operation, limit: 80),
            "flow_type": state.0,
            "dev_mode": String(devMode),
        ]
        event.extra = ["session_id": sessionID].merging(safeContext(context)) { _, new in new }
        event.breadcrumbs = state.1
        client.capture(event: event)
    }

    func flush(timeout: TimeInterval) {
        client.flush(timeout: timeout)
    }

    private func safeContext(_ context: [String: Any?]) -> [String: Any] {
        let allowed = Set(["event_name", "error_type", "status_code", "webview_type", "source", "fallback_type"])
        return AnalyticsSanitizer.properties(context).filter { allowed.contains($0.key) }
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
            initialFlowType: flowType,
            devMode: config.devMode
        )
    }
}
