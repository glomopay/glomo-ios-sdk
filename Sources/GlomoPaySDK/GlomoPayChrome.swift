#if canImport(UIKit)
import UIKit

/// Which colour each surface the SDK draws uses, and what scheme they resolve against.
///
/// **This SDK keeps UIKit's semantic colours.** The Flutter, Android and React Native SDKs take
/// the checkout theme's own hexes from the web monorepo so their chrome matches the page; iOS
/// deliberately does not, and the difference is a decision rather than an omission.
///
/// Two reasons. Semantic colours adapt and hex values do not: `systemBackground` and
/// `secondaryLabel` respond to Increase Contrast, Smart Invert and Reduce Transparency, and this
/// SDK's chrome exists because an exit control once became invisible - hardcoding over a system
/// that is actively trying to keep that control legible for a user who asked for help is the same
/// mistake from the other direction. And a checkout sheet on iOS sits against the host app's own
/// chrome at least as much as against our page, so matching Apple is matching the context the
/// user is actually in. The cost is a cross-SDK difference no end user is positioned to see.
///
/// So what is centralised here is the *mapping* - which semantic colour each surface uses, and
/// what interface style the SDK's own chrome resolves it against - rather than a palette.
enum GlomoPayChrome {
    /// The interface style the SDK's own chrome resolves against.
    ///
    /// ``GlomoColorScheme/auto`` gets `.light`, which is not an oversight. `auto` is resolved
    /// against the host app's appearance and handed to the page as a *request*: the page may
    /// still answer light, because the merchant has no dark-mode flag or the user pinned a
    /// preference. Letting the chrome follow the device puts a dark frame around a light page,
    /// which reads as a defect; a light frame around a light page merely reads as plain. That is
    /// what the other three SDKs do, and before this it was the one place iOS differed - its
    /// semantic colours followed the device for free, so it shipped exactly that failure.
    ///
    /// ``GlomoColorScheme/light`` and ``GlomoColorScheme/dark`` are instructions rather than
    /// requests, so the frame follows them.
    ///
    /// Keyed off the merchant's setting rather than off `ResolvedColorScheme` for the same
    /// reason: the resolved value cannot tell an `auto` that happened to land on dark apart from
    /// a merchant who asked for dark.
    static func style(for scheme: GlomoColorScheme) -> UIUserInterfaceStyle {
        scheme == .dark ? .dark : .light
    }

    /// Every full-bleed surface the SDK paints: the loading views, the error panels, the flow
    /// overlay and its bar.
    static let surface: UIColor = .systemBackground

    /// Captions under a heading - the loading labels and the error body.
    static let secondaryText: UIColor = .secondaryLabel

    /// ``surface`` frozen to `scheme`, for the two containers that cannot take an
    /// `overrideUserInterfaceStyle`.
    ///
    /// The root view and the flow overlay each have a WebView somewhere beneath them whose
    /// appearance is set deliberately and separately - the flow WebView's most of all, which is
    /// left inheriting the host because pinning it would hand the bank's own page a
    /// `prefers-color-scheme` the merchant's dark-mode flag never gated. An override on a
    /// container reaches every subview that has not set one, so these two get a resolved colour
    /// instead and nothing below them is touched.
    ///
    /// The cost is that these two stop adapting to Increase Contrast. Both are background fills
    /// behind an opaque WebView or an opaque loading view, visible only in the gap before a page
    /// paints, so nothing legible is resolved against them.
    static func resolvedSurface(for scheme: GlomoColorScheme) -> UIColor {
        surface.resolvedColor(with: UITraitCollection(userInterfaceStyle: style(for: scheme)))
    }
}
#endif
