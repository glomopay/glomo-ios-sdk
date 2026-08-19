import Foundation

struct SDKRuntimeConfiguration: Equatable {
    let mixpanelToken: String?
    let sentryDSN: String?

    static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledValues: [String: String] = BundledTelemetryConfiguration.load()
    ) -> SDKRuntimeConfiguration {
        SDKRuntimeConfiguration(
            mixpanelToken: value(
                key: "GLOMOPAY_MIXPANEL_TOKEN",
                bundle: bundle,
                environment: environment,
                bundledValues: bundledValues
            ),
            sentryDSN: value(
                key: "GLOMOPAY_SENTRY_DSN",
                bundle: bundle,
                environment: environment,
                bundledValues: bundledValues
            )
        )
    }

    private static func value(
        key: String,
        bundle: Bundle,
        environment: [String: String],
        bundledValues: [String: String]
    ) -> String? {
        [
            environment[key],
            bundle.object(forInfoDictionaryKey: key) as? String,
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

    private static var candidateBundles: [Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.module]
        #else
        let ownerBundle = Bundle(for: ResourceBundleToken.self)
        let containers = [ownerBundle, Bundle.main]
        let resourceBundles = containers.compactMap { container -> Bundle? in
            guard
                let url = container.url(forResource: "GlomoPaySDKConfiguration", withExtension: "bundle")
            else {
                return nil
            }
            return Bundle(url: url)
        }
        return resourceBundles + containers
        #endif
    }
}

private final class ResourceBundleToken: NSObject {}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
