import Foundation

struct AnalyticsEvent {
    let name: String
    let properties: [String: Any]
}

protocol AnalyticsTransporting {
    func send(_ event: AnalyticsEvent) async throws
}

final class MixpanelAnalyticsTracker: AnalyticsTracking {
    private let config: GlomoPayConfig
    private let sessionID: String
    private let sdkVersion: String
    private let transport: AnalyticsTransporting
    private let errorReporter: SDKErrorReporting
    private let deviceProperties: () -> [String: Any?]
    private let now: () -> Date
    private let lock = NSLock()
    private var flowType: String
    private var checkoutURL: URL?

    init(
        config: GlomoPayConfig,
        sessionID: String,
        sdkVersion: String,
        initialFlowType: String,
        transport: AnalyticsTransporting,
        errorReporter: SDKErrorReporting,
        deviceProperties: @escaping () -> [String: Any?],
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.sessionID = sessionID
        self.sdkVersion = sdkVersion
        self.flowType = initialFlowType
        self.transport = transport
        self.errorReporter = errorReporter
        self.deviceProperties = deviceProperties
        self.now = now
    }

    func updateFlowType(_ flowType: String) {
        lock.withLock { self.flowType = flowType }
    }

    func updateCheckoutURL(_ url: URL) {
        lock.withLock { checkoutURL = url }
    }

    func track(_ event: String, properties: [String: Any?]) {
        errorReporter.addBreadcrumb(category: "analytics", message: event, data: ["event_name": event])
        let date = now()
        let state = lock.withLock { (flowType, checkoutURL) }
        var common = deviceProperties()
        common.merge([
            "sdk_version": sdkVersion,
            "sdk_source": "glomo-ios-sdk",
            "platform": "ios",
            "surface": "ios-sdk",
            "flow_type": state.0,
            "order_id": config.orderId,
            "subscription_id": config.subscriptionId,
            "public_key": config.publicKey,
            "checkout_url": state.1?.absoluteString,
            "dev_mode": config.devMode,
            "mock_mode": ConfigManager.isTestOrMock(config.publicKey),
            "time": Int64(date.timeIntervalSince1970 * 1_000),
            "timestamp": Self.formattedTimestamp(date),
            "session_id": sessionID,
            "distinct_id": config.orderId,
        ]) { _, new in new }
        common.merge(properties) { _, new in new }
        let analyticsEvent = AnalyticsEvent(name: event, properties: AnalyticsSanitizer.properties(common))
        Task.detached(priority: .utility) { [transport, errorReporter] in
            do {
                try await transport.send(analyticsEvent)
            } catch {
                GlomoPayLogger.error("Analytics event delivery failed: \(event)", error: error)
                errorReporter.capture(
                    operation: "mixpanel_delivery",
                    error: error,
                    context: ["event_name": event]
                )
            }
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return formatter
    }()
    private static let timestampLock = NSLock()

    private static func formattedTimestamp(_ date: Date) -> String {
        timestampLock.withLock { timestampFormatter.string(from: date) }
    }
}

final class MixpanelHTTPTransport: AnalyticsTransporting {
    static let endpoint = URL(string: "https://api.mixpanel.com/track?ip=1")!
    private let token: String
    private let endpoint: URL
    private let session: URLSession

    init(token: String, endpoint: URL = MixpanelHTTPTransport.endpoint, session: URLSession? = nil) {
        self.token = token
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(_ event: AnalyticsEvent) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        var properties = event.properties
        properties["token"] = token
        request.httpBody = try JSONSerialization.data(withJSONObject: [[
            "event": event.name,
            "properties": properties,
        ]])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (200..<300).contains(status), body == "1" else {
            throw AnalyticsDeliveryError.rejected(statusCode: status)
        }
    }
}

enum AnalyticsDeliveryError: Error {
    case rejected(statusCode: Int)
}

enum AnalyticsFactory {
    static func create(
        config: GlomoPayConfig,
        sessionID: String,
        flowType: String,
        errorReporter: SDKErrorReporting,
        runtimeConfiguration: SDKRuntimeConfiguration = .load()
    ) -> AnalyticsTracking {
        guard let token = runtimeConfiguration.mixpanelToken else { return NoOpAnalyticsTracker() }
        #if canImport(UIKit)
        let properties = { IOSAnalyticsProperties.collect() }
        #else
        let properties = { [String: Any?]() }
        #endif
        return MixpanelAnalyticsTracker(
            config: config,
            sessionID: sessionID,
            sdkVersion: GlomoPaySDKBuild.version,
            initialFlowType: flowType,
            transport: MixpanelHTTPTransport(token: token),
            errorReporter: errorReporter,
            deviceProperties: properties
        )
    }
}
