import Foundation

#if canImport(UIKit)
import UIKit
#endif

public final class GlomoPaySDK {
    public static let shared = GlomoPaySDK()
    private init() {}

    public func validate(_ config: GlomoPayConfig) -> [SdkError] {
        Validator.validate(config: config)
    }

    /// Internal: it had no call sites outside tests, and a URL builder is not part of the
    /// integration contract. `startCheckout` is the entry point.
    func checkoutURL(for config: GlomoPayConfig, orderType: String = "standard") throws -> URL {
        let errors = validate(config)
        guard errors.isEmpty else { throw errors[0] }
        guard let url = ConfigManager.getCheckoutURL(config, orderType: orderType) else {
            throw SdkError(type: .unknown, message: "Unable to build checkout URL")
        }
        return url
    }

#if canImport(UIKit)
    /// Presents the checkout and returns a handle for dismissing it.
    ///
    /// The SDK holds `listener` weakly: it does not keep a merchant object alive. Retain the
    /// listener for at least as long as the checkout, or its callbacks cannot be delivered - a
    /// coordinator or handler that nothing else references will be released mid-checkout and the
    /// result will be lost. A dropped listener is reported as `Listener Unavailable` in analytics
    /// and captured to Sentry rather than failing silently, but the result is still gone.
    ///
    /// Callbacks are delivered on the main queue. They must not throw or trap: Swift has no
    /// catchable exception mechanism, so a force-unwrap of nil or an out-of-range index inside a
    /// callback traps the host process and the SDK cannot contain it.
    @discardableResult
    @MainActor
    public func startCheckout(
        from presenter: UIViewController,
        config: GlomoPayConfig,
        orderType: String = "auto",
        listener: GlomoPayListener? = nil,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) -> GlomoPayCheckoutHandle {
        let handle = GlomoPayCheckoutHandle()
        Task { @MainActor [weak presenter] in
            let telemetryRuntime = await SDKTelemetryRuntime.prepared()
            guard let presenter else { return }
            let checkout = GlomoPayCheckoutViewController(
                config: config,
                orderType: orderType,
                listener: listener,
                apiClient: nil,
                telemetryRuntime: telemetryRuntime
            )
            handle.attach(checkout)
            let navigationController = UINavigationController(rootViewController: checkout)
            navigationController.modalPresentationStyle = .pageSheet
            if #available(iOS 15.0, *) {
                navigationController.sheetPresentationController?.prefersGrabberVisible = true
                navigationController.sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge = false
            }
            presenter.present(navigationController, animated: animated, completion: completion)
        }
        return handle
    }
#endif
}

#if canImport(UIKit)
/// Controls only the checkout it was returned for.
///
/// `close()` before the checkout has finished presenting is honoured once it appears; after the
/// checkout has finished it does nothing. The listener receives
/// `onPaymentTerminate(.programmatic)` exactly once.
@MainActor
public final class GlomoPayCheckoutHandle {
    private weak var checkout: GlomoPayCheckoutViewController?
    private var closeRequested = false

    init() {}

    func attach(_ checkout: GlomoPayCheckoutViewController) {
        self.checkout = checkout
        if closeRequested { checkout.closeCheckout() }
    }

    public func close() {
        closeRequested = true
        checkout?.closeCheckout()
    }
}
#endif
