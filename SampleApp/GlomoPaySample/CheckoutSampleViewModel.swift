import Combine
import Foundation
import GlomoPaySDK
import UIKit

@MainActor
final class CheckoutSampleViewModel: ObservableObject, GlomoPayListener {
    @Published var publicKey = ""
    @Published var identifier = ""
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
            subscriptionId: isSubscription ? trimmedIdentifier : nil
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
            model.log("onPaymentSuccess orderId=\(payload.orderId)")
        }
    }

    nonisolated func onPaymentFailure(_ payload: GlomoPayPayload) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "FAILURE: \(payload.orderId)"
            model.log("onPaymentFailure orderId=\(payload.orderId)")
        }
    }

    nonisolated func onSdkError(_ errors: [SdkError]) {
        updateOnMain { model in
            model.isStarting = false
            model.status = errors.map(\.message).joined(separator: "\n")
            model.log("onSdkError \(errors.map(\.type.rawValue).joined(separator: ","))")
        }
    }

    /// Required by the SDK: a bank transfer is a journey, not a payment. There is no paymentId and
    /// no signature here, and no money has moved - reconcile it against the order server-side.
    nonisolated func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "JOURNEY: \(payload.journeyType.rawValue)"
            model.log(
                "onUserJourneyCompleted \(payload.journeyType.rawValue) orderId=\(payload.orderId) "
                    + "ref=\(payload.transactionReference ?? "-") status=\(payload.status ?? "-")"
            )
        }
    }

    nonisolated func onConnectionError(_ error: ConnectionError) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "CONNECTION ERROR: \(error.message)"
            model.log("onConnectionError \(error.type.rawValue) autoClose=\(error.shouldAutoClose)")
        }
    }

    nonisolated func onPaymentTerminate(_ source: TerminationSource) {
        updateOnMain { model in
            model.isStarting = false
            model.status = "TERMINATED: \(source.rawValue)"
            model.log("onPaymentTerminate \(source.rawValue)")
        }
    }

    /// The SDK has no diagnostic event channel, so the sample logs the typed callbacks it gets.
    func log(_ line: String) {
        events.append("- \(line)")
        if events.count > 100 { events.removeFirst() }
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
