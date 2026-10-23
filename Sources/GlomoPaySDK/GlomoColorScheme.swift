import Foundation

/// The colour scheme the host app asks the checkout page to present.
///
/// A request, not a switch: the page decides, against the merchant's own dashboard settings, so
/// ``dark`` does not guarantee a dark checkout.
public enum GlomoColorScheme: String, Sendable, Equatable {
    /// Follow the host app's appearance. The default.
    ///
    /// Resolved from the checkout's own trait collection, so an app that overrides its appearance
    /// with `overrideUserInterfaceStyle` gets what it set rather than what the device is on. That
    /// is usually what a merchant means.
    ///
    /// What `auto` derives from is a per-platform decision and differs across the Glomo SDKs on
    /// purpose; only ``light`` and ``dark`` are contractual.
    case auto

    /// Ask for light, whatever the host app is doing.
    case light

    /// Ask for dark, whatever the host app is doing.
    case dark
}

/// The two values the checkout page ever sees.
///
/// A separate type from ``GlomoColorScheme`` so "never send `auto` on the wire" is a compile-time
/// guarantee rather than a comment: this one cannot hold a third value.
enum ResolvedColorScheme: String, Sendable, Equatable {
    case light
    case dark

    var wireName: String { rawValue }
}

/// The query parameter the checkout and carousel pages read at boot.
let glomoColorSchemeQueryItem = "colorScheme"

/// Scheme, host and port, compared case-insensitively. Nil on either side is not a match.
///
/// A free function rather than a method on the controller so the rule is reachable from the
/// macOS test run, where the controller is compiled out entirely.
func sameColorSchemeOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
    guard let lhs, let rhs,
          let lhsScheme = lhs.scheme?.lowercased(), let rhsScheme = rhs.scheme?.lowercased(),
          let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased()
    else { return false }
    return lhsScheme == rhsScheme && lhsHost == rhsHost && lhs.port == rhs.port
}

/// Whether a *live* colour-scheme push may reach a surface whose committed page is `loaded`.
///
/// Looser than the page-finished gate in one specific way: a surface that has committed nothing
/// yet is allowed. There is no page there to mis-theme, the WebView is the SDK's own, and the
/// only document that can land in it is one the SDK loads - which will carry the scheme on its
/// URL anyway. Once a page *is* committed the rule is the strict one, because that is the case
/// the gate exists for: a WebView sitting on a bank or 3DS page is not ours to restyle.
func mayPushColorScheme(loaded: URL?, expected: URL?) -> Bool {
    loaded == nil || sameColorSchemeOrigin(loaded, expected)
}

/// Returns `url` with ``glomoColorSchemeQueryItem`` set to `resolved`.
///
/// An upsert rather than a rewrite, and the distinction is load-bearing: the page strips the
/// parameter with `history.replaceState` once it has read it, so on most reload paths there is no
/// value to replace and it has to be put back. Replacing in place also keeps a reload from
/// appending a second copy.
///
/// Every load the SDK performs goes through this, not just the first - a retry would otherwise
/// replay the URL built at open and put back a scheme the host has since changed.
/// Anything that is not http(s) is returned untouched. `URLComponents` will cheerfully hang a
/// query off a `mailto:`, and a parameter the page can never read is worse than none.
func withColorScheme(_ url: URL, _ resolved: ResolvedColorScheme) -> URL {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    var items = (components.queryItems ?? []).filter { $0.name != glomoColorSchemeQueryItem }
    items.append(URLQueryItem(name: glomoColorSchemeQueryItem, value: resolved.wireName))
    components.queryItems = items
    return components.url ?? url
}

extension GlomoColorScheme {
    /// Resolves the merchant's setting against the host's current appearance.
    ///
    /// Takes a `Bool` rather than a `UITraitCollection` so the resolution rules are reachable from
    /// the macOS test run, where UIKit does not exist and the checkout controller is compiled out
    /// of the test binary entirely.
    func resolve(hostIsDark: Bool) -> ResolvedColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return hostIsDark ? .dark : .light
        }
    }
}
