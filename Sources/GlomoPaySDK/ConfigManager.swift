import Foundation

public enum ConfigManager {
    public static let defaultLRSBaseURL = "https://lrs-checkout.glomopay.com/"
    public static let defaultStandardBaseURL = "https://checkout.glomopay.com/"
    public static let carouselBaseURL = "https://glomopay-utilities.web.app/lrs-education-carousel/"

    public static func getBaseURL(_ config: GlomoPayConfig, orderType: String = "standard") -> URL? {
        let value = config.server?.isEmpty == false
            ? (config.server!.hasSuffix("/") ? config.server! : config.server! + "/")
            : (orderType.lowercased() == "lrs" ? defaultLRSBaseURL : defaultStandardBaseURL)
        return URL(string: value)
    }

    public static func getCheckoutURL(_ config: GlomoPayConfig, orderType: String = "standard") -> URL? {
        getCheckoutURL(config, orderType: orderType, journeyID: nil, colorScheme: nil)
    }

    /// `colorScheme` is the already-resolved scheme; `auto` never reaches here. Omitted when nil,
    /// which leaves the page on its own default.
    ///
    /// Internal because the resolved type is: resolving needs the checkout's trait collection, so
    /// no caller outside this SDK is in a position to supply one. A scheme change mid-checkout
    /// must NOT rebuild this URL - a reload destroys the payment.
    /// `GlomoPayInjectionScripts.colorScheme` is the live path.
    static func getCheckoutURL(
        _ config: GlomoPayConfig,
        orderType: String = "standard",
        journeyID: String? = nil,
        colorScheme: ResolvedColorScheme? = nil
    ) -> URL? {
        guard let baseURL = getBaseURL(config, orderType: orderType),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = [
            URLQueryItem(name: "orderId", value: config.checkoutId ?? ""),
            URLQueryItem(name: "publicKey", value: config.publicKey),
            URLQueryItem(name: "mode", value: getMode(config.publicKey)),
        ]
        if let journeyID, !journeyID.isEmpty {
            items.append(URLQueryItem(name: "journeyId", value: journeyID))
        }
        // Three names for one concept, by design: the property is `appColorScheme`, the wire is
        // `colorScheme`, the page hook is `glomoSetColorScheme`. The README says so, so nobody
        // assumes the wire was renamed with the property.
        if let colorScheme {
            items.append(URLQueryItem(name: glomoColorSchemeQueryItem, value: colorScheme.wireName))
        }
        components.queryItems = items
        return components.url
    }

    /// `product` and `surface` let the hosted page tell which SDK and platform it is serving,
    /// matching the parameters Flutter v2.0.0 added.
    public static func getCarouselURL(_ config: GlomoPayConfig) -> URL? {
        getCarouselURL(config, colorScheme: nil)
    }

    /// `colorScheme` carries the same resolved value on the same param name - the carousel is on
    /// the same contract as the checkout pages.
    static func getCarouselURL(_ config: GlomoPayConfig, colorScheme: ResolvedColorScheme?) -> URL? {
        var components = URLComponents(string: carouselBaseURL)
        var items = [
            URLQueryItem(name: "orderId", value: config.orderId ?? ""),
            URLQueryItem(name: "publicKey", value: config.publicKey),
            URLQueryItem(name: "product", value: "checkout-ios-sdk"),
            URLQueryItem(name: "surface", value: "ios"),
        ]
        if let colorScheme {
            items.append(URLQueryItem(name: glomoColorSchemeQueryItem, value: colorScheme.wireName))
        }
        components?.queryItems = items
        return components?.url
    }

    public static func getMode(_ publicKey: String) -> String {
        publicKey.hasPrefix("test_") || publicKey.hasPrefix("mock_") ? "mock" : "live"
    }

    public static func isTestOrMock(_ publicKey: String) -> Bool {
        publicKey.hasPrefix("test_") || publicKey.hasPrefix("mock_")
    }

    public static func detectOrderType(_ orderData: [String: Any]) -> String {
        if let explicit = orderData["orderType"] as? String, !explicit.isEmpty { return explicit }
        return orderData["lrs"] != nil ? "lrs" : "standard"
    }

    /// Whether the merchant has dark mode switched on, from the order response.
    ///
    /// The key is snake_case and has no camelCase alias, unlike `order_type`/`orderType` on the
    /// same payload. An identity check against `true` rather than a truthiness one: a missing key,
    /// a null, the string "true" and a number all mean light. Light is the safe answer because the
    /// page renders light whenever the flag is off, so guessing dark is the only way to be wrong.
    ///
    /// `as? Bool` is NOT that identity check on this input, which is why the cast goes through
    /// `NSNumber` instead. The dictionary comes from `JSONSerialization`, which boxes JSON
    /// booleans and JSON numbers alike into `NSNumber`, and bridging back hands `1` and `1.0` to
    /// Swift as `true`. Only the CoreFoundation type tells the two apart once they are in the
    /// dictionary.
    ///
    /// Here rather than on the checkout controller so it is reachable from the macOS test run,
    /// where everything behind `canImport(UIKit)` is compiled out.
    static func darkModeEnabled(_ orderData: [String: Any]) -> Bool {
        guard let value = orderData["dark_mode_enabled"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
}
