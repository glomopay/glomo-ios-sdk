import Foundation

struct SDKRuntimeConfiguration: Equatable {
    let mixpanelToken: String?
    let sentryDSN: String?

    static func load(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> SDKRuntimeConfiguration {
        SDKRuntimeConfiguration(
            mixpanelToken: value(key: "GLOMOPAY_MIXPANEL_TOKEN", bundle: bundle, environment: environment),
            sentryDSN: value(key: "GLOMOPAY_SENTRY_DSN", bundle: bundle, environment: environment)
        )
    }

    private static func value(key: String, bundle: Bundle, environment: [String: String]) -> String? {
        let raw = (bundle.object(forInfoDictionaryKey: key) as? String) ?? environment[key]
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
