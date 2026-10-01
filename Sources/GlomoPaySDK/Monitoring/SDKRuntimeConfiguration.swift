import Foundation

struct SDKRuntimeConfiguration: Equatable {
    let mixpanelToken: String?
    let sentryDSN: String?

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledValues: [String: String] = BundledTelemetryConfiguration.load()
    ) -> SDKRuntimeConfiguration {
        SDKRuntimeConfiguration(
            mixpanelToken: value(
                key: "GLOMOPAY_MIXPANEL_TOKEN",
                environment: environment,
                bundledValues: bundledValues
            ),
            sentryDSN: value(
                key: "GLOMOPAY_SENTRY_DSN",
                environment: environment,
                bundledValues: bundledValues
            )
        )
    }

    private static func value(
        key: String,
        environment: [String: String],
        bundledValues: [String: String]
    ) -> String? {
        [
            environment[key],
            bundledValues[key],
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        .first
    }
}

private enum BundledTelemetryConfiguration {
    private static let resourceName = "GlomoPayTelemetryConfiguration"

    static func load() -> [String: String] {
        for bundle in candidateBundles {
            guard
                let url = bundle.url(forResource: resourceName, withExtension: "plist"),
                let data = try? Data(contentsOf: url),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let values = plist as? [String: String]
            else {
                continue
            }
            return values
        }
        return [:]
    }

    /// `Bundle.module` only. The SDK ships through Swift Package Manager alone, so the telemetry
    /// resource is always the package's own - never the merchant's `Bundle.main`, which could
    /// otherwise supply a `GLOMOPAY_MIXPANEL_TOKEN` or `GLOMOPAY_SENTRY_DSN` and redirect every
    /// event's destination.
    private static var candidateBundles: [Bundle] { [Bundle.module] }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
