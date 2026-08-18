import Foundation
import Sentry

final class IsolatedSentryErrorReporter: SDKErrorReporting {
    private let client: SentryClient?
    private let sessionID: String
    private let devMode: Bool
    private let lock = NSLock()
    private var flowType: String
    private var breadcrumbs: [Breadcrumb] = []

    init(dsn: String, sessionID: String, initialFlowType: String, devMode: Bool) {
        let options = Options()
        options.dsn = dsn
        options.debug = false
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableSwizzling = false
        options.tracesSampleRate = 0
        self.client = SentryClient(options: options)
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
        let state: (String, [Breadcrumb]) = lock.withCriticalScope { (flowType, breadcrumbs) }
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
        _ = client?.capture(event: event)
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
        runtimeConfiguration: SDKRuntimeConfiguration = .load()
    ) -> SDKErrorReporting {
        guard let dsn = runtimeConfiguration.sentryDSN else { return NoOpSDKErrorReporter() }
        return IsolatedSentryErrorReporter(
            dsn: dsn,
            sessionID: sessionID,
            initialFlowType: flowType,
            devMode: config.devMode
        )
    }
}

private extension NSLock {
    func withCriticalScope<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
