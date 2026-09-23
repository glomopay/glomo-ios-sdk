import Foundation

/// Declaration order is execution order: the funnel compares by index and only ever advances,
/// so reordering these changes behaviour. The wire names are shared with the other SDKs so the
/// platforms stay comparable in analytics.
enum CheckoutOpenStep: Int, CaseIterable {
    case webViewCreated
    case urlResolved
    case navigationStarted
    case navigationFinished
    case bridgeReady

    var wireName: String {
        switch self {
        case .webViewCreated: return "webview_created"
        case .urlResolved: return "url_resolved"
        case .navigationStarted: return "navigation_started"
        case .navigationFinished: return "navigation_finished"
        case .bridgeReady: return "bridge_ready"
        }
    }
}

/// Why the checkout never opened, for the one incident class that is otherwise undiagnosable:
/// the user sat on a spinner and nothing was reported.
struct CheckoutOpenFunnel {
    private var reachedStep: CheckoutOpenStep? = nil
    private var timeoutReported = false

    /// The first step is the reporting default before any event has fired. Keeping the actual
    /// reached state optional lets `.webViewCreated` advance a fresh funnel and emit its event.
    var lastStep: CheckoutOpenStep { reachedStep ?? .webViewCreated }

    /// Monotonic: a redirect or a re-navigation cannot move the funnel backwards.
    mutating func advance(_ step: CheckoutOpenStep) -> Bool {
        if let reachedStep {
            guard step.rawValue > reachedStep.rawValue else { return false }
        }
        reachedStep = step
        return true
    }

    var didOpen: Bool { reachedStep == .bridgeReady }

    /// The step reached when the budget ran out, once per attempt. Nil when the checkout has
    /// already opened or a timeout was already reported.
    mutating func timeout() -> String? {
        guard !timeoutReported, !didOpen else { return nil }
        timeoutReported = true
        return lastStep.wireName
    }

    /// True when the page came up after a timeout had already been reported.
    ///
    /// Reported as its own event on purpose. It is not a correction and the difference between
    /// the two counts is not a failure rate: a timeout says the budget was exceeded, and this
    /// says the checkout arrived anyway.
    var openedAfterTimeout: Bool { timeoutReported && didOpen }
}

/// Derived, never hard-coded. A hard-coded watchdog went stale silently twice in the reference
/// implementation, and iOS's own API timeout differs from Flutter's, so a copied number would be
/// wrong on arrival.
enum CheckoutOpenBudget {
    /// Advisory: it raises a connection error that does not close the checkout, because the page
    /// may be seconds away and `autoCloseOnConnectionError` defaults to true.
    static let renderTimeout: TimeInterval = 15
    static let margin: TimeInterval = 5

    static var watchdog: TimeInterval {
        GlomoPayApiClient.requestTimeout + renderTimeout + margin
    }
}
