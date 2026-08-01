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

    public func checkoutURL(for config: GlomoPayConfig, orderType: String = "standard") throws -> URL {
        let errors = validate(config)
        guard errors.isEmpty else { throw errors[0] }
        guard let url = ConfigManager.getCheckoutURL(config, orderType: orderType) else {
            throw SdkError(type: .unknown, message: "Unable to build checkout URL")
        }
        return url
    }

#if canImport(UIKit)
    @MainActor
    public func startCheckout(
        from presenter: UIViewController,
        config: GlomoPayConfig,
        orderType: String = "auto",
        listener: GlomoPayListener? = nil,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        let checkout = GlomoPayCheckoutViewController(
            config: config,
            orderType: orderType,
            listener: listener
        )
        let navigationController = UINavigationController(rootViewController: checkout)
        navigationController.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            navigationController.sheetPresentationController?.prefersGrabberVisible = true
            navigationController.sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        presenter.present(navigationController, animated: animated, completion: completion)
    }
#endif
}
