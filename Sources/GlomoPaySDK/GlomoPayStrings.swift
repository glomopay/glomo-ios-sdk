import Foundation

/// User-facing text, looked up so it can be localised and overridden.
///
/// Every string was hardcoded in Swift with no strings table anywhere in the package, so nothing
/// a paying user read could be translated. A host that ships its own `Localizable.strings` entry
/// for one of these keys wins, because the main bundle is searched before the SDK's.
enum GlomoPayStrings {
    static var loadingCheckout: String { localized("glomopay.loading_checkout", "Loading checkout...") }
    static var openingSecurePage: String { localized("glomopay.opening_secure_page", "Opening secure page...") }
    static var recoveringCheckout: String { localized("glomopay.recovering_checkout", "Recovering checkout...") }
    static var checkoutTitle: String { localized("glomopay.checkout_title", "Checkout") }
    static var connectionErrorTitle: String { localized("glomopay.connection_error_title", "Connection problem") }
    static var connectionErrorMessage: String {
        localized(
            "glomopay.connection_error_message",
            "Unable to load this page. Please check your connection and try again."
        )
    }
    static var retry: String { localized("glomopay.retry", "Retry") }
    static var cancel: String { localized("glomopay.cancel", "Cancel") }
    static var close: String { localized("glomopay.close", "Close") }
    static var back: String { localized("glomopay.back", "Back") }

    private static func localized(_ key: String, _ fallback: String) -> String {
        for bundle in candidateBundles {
            let value = bundle.localizedString(forKey: key, value: nil, table: tableName)
            if value != key { return value }
        }
        return fallback
    }

    private static let tableName = "GlomoPayLocalizable"

    /// The host's main bundle first, so a merchant can override any string, then the SDK's own
    /// resources. Mirrors how the telemetry resource is resolved across SPM and CocoaPods.
    private static var candidateBundles: [Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.main, Bundle.module]
        #else
        let ownerBundle = Bundle(for: StringsBundleToken.self)
        let containers = [Bundle.main, ownerBundle]
        let resourceBundles = containers.compactMap { container -> Bundle? in
            guard let url = container.url(forResource: "GlomoPaySDKResources", withExtension: "bundle") else {
                return nil
            }
            return Bundle(url: url)
        }
        return containers + resourceBundles
        #endif
    }
}

private final class StringsBundleToken: NSObject {}
