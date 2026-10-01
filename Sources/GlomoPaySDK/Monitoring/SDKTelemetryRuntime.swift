import Foundation

/// Process-wide telemetry dependencies. Checkout-specific state remains in the
/// reporter and tracker wrappers created for each presentation.
final class SDKTelemetryRuntime: @unchecked Sendable {
    static let shared = SDKTelemetryRuntime(configuration: .load())
    private static let preparationTask = Task.detached(priority: .userInitiated) {
        SDKTelemetryRuntime.shared
    }

    let configuration: SDKRuntimeConfiguration
    let sentryClient: SentryEnvelopeClient?
    let mixpanelTransport: MixpanelHTTPTransport?

    init(
        configuration: SDKRuntimeConfiguration,
        sentrySessionConfiguration: URLSessionConfiguration = SentryEnvelopeClient.defaultSessionConfiguration()
    ) {
        self.configuration = configuration
        self.sentryClient = configuration.sentryDSN.flatMap {
            SentryEnvelopeClient(dsn: $0, sessionConfiguration: sentrySessionConfiguration)
        }
        self.mixpanelTransport = configuration.mixpanelToken.map { MixpanelHTTPTransport(token: $0) }
    }

    static func prepared() async -> SDKTelemetryRuntime {
        await preparationTask.value
    }
}
