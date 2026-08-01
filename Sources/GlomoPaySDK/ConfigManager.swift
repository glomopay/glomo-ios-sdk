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
        guard let baseURL = getBaseURL(config, orderType: orderType),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "orderId", value: config.checkoutId ?? ""),
            URLQueryItem(name: "publicKey", value: config.publicKey),
            URLQueryItem(name: "mode", value: getMode(config.publicKey)),
        ]
        return components.url
    }

    public static func getCarouselURL(_ config: GlomoPayConfig) -> URL? {
        var components = URLComponents(string: carouselBaseURL)
        components?.queryItems = [
            URLQueryItem(name: "orderId", value: config.orderId ?? ""),
            URLQueryItem(name: "publicKey", value: config.publicKey),
        ]
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
}
