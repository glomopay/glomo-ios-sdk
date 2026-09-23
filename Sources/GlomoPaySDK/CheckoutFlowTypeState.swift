import Foundation

struct CheckoutFlowTypeState {
    let requestedOrderType: String
    private(set) var resolvedOrderType: String?

    init(requestedOrderType: String) {
        self.requestedOrderType = requestedOrderType
    }

    mutating func resolve(_ orderType: String) {
        resolvedOrderType = orderType
    }

    var currentOrderType: String {
        resolvedOrderType ?? requestedOrderType
    }
}
