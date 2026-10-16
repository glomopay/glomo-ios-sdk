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
