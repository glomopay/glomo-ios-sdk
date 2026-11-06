import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Origin allow-list for the privileged bridge messages.
///
/// The flow WebView loads bank and 3-D Secure pages at the top level, and
/// `GlomoPayInjectionScripts.flow` installs a `window.opener.postMessage` shim on every document
/// it loads — including those bank pages. Whatever that shim is handed arrives on the bridge as
/// `{"type": "message", ...}`, which is the envelope that carries `payment.success`. The shim
/// exists for GlomoPay's own return page at the end of the redirect chain; a bank page inherits it
/// only because the injection runs per document.
///
/// So the question is not which WebView a message came from, but which document sent it.
enum TrustedOrigin {
    /// `scheme://host[:port]`, lowercased, with the scheme's default port dropped.
    ///
    /// Normalising matters because the two sides are written by different people: the allow-list
    /// comes from `ConfigManager`'s base URLs, where a port may or may not be spelled out, and
    /// what it is compared against is reported by WebKit.
    static func origin(of url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return nil }
        return normalised(scheme: scheme, host: host, port: url.port)
    }

    #if canImport(WebKit)
    /// The origin WebKit itself attributes the message to.
    ///
    /// Preferred over the WebView's URL: this is the sending frame's own origin, reported by the
    /// engine, and page script cannot forge it. `WKSecurityOrigin.port` is 0 for the scheme's
    /// default, which `normalised` already drops.
    static func origin(of securityOrigin: WKSecurityOrigin) -> String? {
        let scheme = securityOrigin.protocol.lowercased()
        guard scheme == "https" || scheme == "http" else { return nil }
        let host = securityOrigin.host.lowercased()
        guard !host.isEmpty else { return nil }
        return normalised(scheme: scheme, host: host, port: securityOrigin.port)
    }
    #endif

    private static func normalised(scheme: String, host: String, port: Int?) -> String {
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port, port != 0, port != defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// Every origin this SDK serves a page from, for the config in hand.
    ///
    /// Derived from the same base URLs the SDK navigates to rather than written out, so a merchant
    /// on a custom `GlomoPayConfig.server` is covered without a second list that can drift from
    /// the first. All three are trusted for every WebView rather than one per journey: the set
    /// still excludes every bank, which is the boundary that matters, and a narrower list would
    /// start dropping our own pages the first time a journey moves to a sibling host.
    static func pageOrigins(for config: GlomoPayConfig) -> Set<String> {
        var origins: Set<String> = []
        for url in [
            ConfigManager.getBaseURL(config, orderType: "standard"),
            ConfigManager.getBaseURL(config, orderType: "lrs"),
            URL(string: ConfigManager.carouselBaseURL),
        ] {
            if let origin = origin(of: url) { origins.insert(origin) }
        }
        return origins
    }
}
