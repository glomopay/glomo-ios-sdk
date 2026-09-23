import Foundation

/// Process-wide telemetry dependencies. Checkout-specific state remains in the
/// reporter and tracker wrappers created for each presentation.
final class SDKTelemetryRuntime: @unchecked Sendable {
    static let shared = SDKTelemetryRuntime(configuration: .load())
    private static let preparationTask = Task.detached(priority: .userInitiated) {
        SDKTelemetryRuntime.shared
    }

    let configuration: SDKRuntimeConfiguration
    let sentryClient: IsolatedSentryClient?
    let mixpanelTransport: MixpanelHTTPTransport?

    init(configuration: SDKRuntimeConfiguration) {
        self.configuration = configuration
        self.sentryClient = configuration.sentryDSN.map { IsolatedSentryClient(dsn: $0) }
        self.mixpanelTransport = configuration.mixpanelToken.map { MixpanelHTTPTransport(token: $0) }
    }

    static func prepared() async -> SDKTelemetryRuntime {
        await preparationTask.value
    }
}
