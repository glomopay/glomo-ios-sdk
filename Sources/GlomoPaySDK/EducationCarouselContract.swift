import Foundation

/// Whether the LRS education carousel has anything to show for this order.
enum EducationCarouselState {
    case pending
    case hasContent
    case noContent
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

    /// The page sends `{ event: 'lrs.has_education_steps', hasContent: true|false }`.
    /// The field names are `event` and `hasContent`; anything keyed `type`/`value` is a
    /// different contract and is not what the hosted page emits.
    static func availabilitySignal(_ data: [String: Any]) -> Bool? {
        guard data["event"] as? String == eventName else { return nil }
        return data["hasContent"] as? Bool
    }

    /// For payloads whose event name has already been matched by the caller, such as the
    /// checkout page forwarding the signal through the payment-event channel, where the
    /// name may arrive under `type` instead of `event`.
    static func hasContent(_ data: [String: Any]) -> Bool? {
        data["hasContent"] as? Bool
    }

    static func parseAvailabilitySignal(rawMessage: String) -> Bool? {
        guard let data = rawMessage.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return availabilitySignal(dictionary)
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
