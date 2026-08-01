import Foundation

public enum Validator {
    public static func isValidPublicKey(_ value: String) -> Bool {
        (value.hasPrefix("live_") || value.hasPrefix("test_") || value.hasPrefix("mock_")) && value.count > 5
    }

    public static func validateCheckoutIdentifier(orderId: String?, subscriptionId: String?) -> [SdkError] {
        if orderId?.isEmpty == false && subscriptionId?.isEmpty == false {
            return [SdkError(type: .validationError, message: "Provide either order ID or subscription ID, not both.", field: "identifier")]
        }
        if let orderId, !orderId.isEmpty {
            return orderId.hasPrefix("order_") && orderId.count > 6 ? [] : [invalid("Invalid order ID format", field: "orderId")]
        }
        if let subscriptionId, !subscriptionId.isEmpty {
            return subscriptionId.hasPrefix("sub_") && subscriptionId.count > 4 ? [] : [invalid("Invalid subscription ID format", field: "subscriptionId")]
        }
        return [invalid("Order ID or subscription ID is required", field: "identifier")]
    }

    public static func validate(config: GlomoPayConfig) -> [SdkError] {
        var errors: [SdkError] = []
        if !isValidPublicKey(config.publicKey) { errors.append(invalid("Invalid public key format", field: "publicKey")) }
        errors.append(contentsOf: validateCheckoutIdentifier(orderId: config.orderId, subscriptionId: config.subscriptionId))
        if let server = config.server, !server.isEmpty, URL(string: server) == nil {
            errors.append(invalid("Invalid server URL", field: "server"))
        }
        return errors
    }

    public static func isValidPaymentPayload(_ payload: GlomoPayPayload) -> Bool {
        !payload.orderId.isEmpty && !(payload.paymentId?.isEmpty ?? true) && !(payload.signature?.isEmpty ?? true)
    }

    private static func invalid(_ message: String, field: String) -> SdkError {
        SdkError(type: .validationError, message: message, field: field)
    }
}
