import Foundation

/// Whether the LRS education carousel is shown for this order.
///
/// There is deliberately no "no content" state driven by the page. The page only ever announces
/// that it has content; silence means hidden. `failed` is reached only when the carousel WebView
/// itself fails, never from a page message.
enum EducationCarouselState {
    case pending
    case hasContent
    case failed
}

/// Proportions of the flow overlay given to the back bar and the carousel strip.
///
/// Matching Flutter: 5% back bar + 15% carousel when showing, and a fixed 48pt bar when not -
/// a percentage in the hidden case would give the bar a different height on every screen size.
struct EducationCarouselLayout: Equatable {
    let showsCarousel: Bool
    let barFraction: Double?
    let barHeight: Double?
    let carouselFraction: Double

    static let hidden = EducationCarouselLayout(
        showsCarousel: false,
        barFraction: nil,
        barHeight: 48,
        carouselFraction: 0
    )

    static let showing = EducationCarouselLayout(
        showsCarousel: true,
        barFraction: 0.05,
        barHeight: nil,
        carouselFraction: 0.15
    )
}

/// The message contract with the hosted carousel page.
enum EducationCarouselContract {
    static let eventName = "lrs.has_education_steps"

    /// The hosted page (glomopay-checkout, `apps/utilities/src/features/education-steps/services/
    /// lrs-carousel.event-emitter.ts`) posts `{ type: 'lrs.has_education_steps', value: true }`,
    /// and only ever with `true`: "absence of event signals 'no content' to native SDKs"
    /// (`components/lrs-education-carousel.tsx`). React Native reads the same contract.
    ///
    /// So this is true only for that exact message with a JSON boolean `true`. `value: false`,
    /// a `1` or `"true"`, the `{ event, hasContent }` shape and anything malformed are not
    /// signals and leave the carousel as it was.
    static func isContentSignal(_ data: [String: Any]) -> Bool {
        guard data["type"] as? String == eventName, let value = data["value"] as? NSNumber else {
            return false
        }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
    }

    static func isContentSignal(rawMessage: String) -> Bool {
        guard let data = rawMessage.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        return isContentSignal(dictionary)
    }

    static func layout(
        state: EducationCarouselState,
        isLRSOrder: Bool,
        isSubscription: Bool
    ) -> EducationCarouselLayout {
        let shows = isLRSOrder && !isSubscription && state == .hasContent
        return shows ? .showing : .hidden
    }
}
