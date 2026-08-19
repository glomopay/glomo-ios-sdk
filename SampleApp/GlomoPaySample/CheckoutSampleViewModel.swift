import Combine
import Foundation
import GlomoPaySDK
import UIKit

@MainActor
final class CheckoutSampleViewModel: ObservableObject, GlomoPayListener {
    @Published var publicKey = ""
    @Published var identifier = ""
    @Published var devMode = true
    @Published var status = "Ready"
    @Published var events: [String] = []
    @Published var isStarting = false

    private weak var presenter: UIViewController?

    func setPresenter(_ presenter: UIViewController) {
        self.presenter = presenter
    }

    func startCheckout() {
        guard let presenter else {
            status = "Unable to present checkout."
            return
        }

        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSubscription = trimmedIdentifier.hasPrefix("sub_")
        let config = GlomoPayConfig(
            publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            orderId: isSubscription ? nil : trimmedIdentifier,
            subscriptionId: isSubscription ? trimmedIdentifier : nil,
            devMode: devMode
        )
        let errors = GlomoPaySDK.shared.validate(config)
        guard errors.isEmpty else {
            status = errors.map(\.message).joined(separator: "\n")
            return
        }

        events.removeAll()
        isStarting = true
        status = "Starting checkout..."
        GlomoPaySDK.shared.startCheckout(
            from: presenter,
            config: config,
            orderType: "auto",
            listener: self
        ) { [weak self] in
            self?.isStarting = false
        }
    }

    nonisolated func onPaymentSuccess(_ payload: GlomoPayPayload) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "SUCCESS: \(payload.orderId)"
        }
    }

    nonisolated func onPaymentFailure(_ payload: GlomoPayPayload) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "FAILURE: \(payload.orderId)"
        }
    }

    nonisolated func onSdkError(_ errors: [SdkError]) {
        updateOnMain { model in
            model.isStarting = false
            model.status = errors.map(\.message).joined(separator: "\n")
        }
    }

    nonisolated func onConnectionError(_ error: ConnectionError) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "CONNECTION ERROR: \(error.message)"
        }
    }

    nonisolated func onPaymentTerminate(_ source: TerminationSource) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "TERMINATED: \(source.rawValue)"
        }
    }

    nonisolated func onEvent(name: String, payload: [String: Any]) {
        updateOnMain { model in
            model.events.append("- \(name) \(payload)")
            if model.events.count > 100 {
                model.events.removeFirst()
            }
        }
    }

    private nonisolated func updateOnMain(
        _ update: @escaping @MainActor (CheckoutSampleViewModel) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            update(self)
        }
    }
}
