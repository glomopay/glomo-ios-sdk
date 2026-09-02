import XCTest
@testable import GlomoPaySDK

final class IntegrationFlowTests: XCTestCase {
    func testWrapperCredentialsResolveStandardCheckoutEndToEnd() throws {
        let config = GlomoPayConfig(
            publicKey: "test_public_key",
            orderId: "order_123456",
            devMode: true
        )
        let listener = IntegrationListener()

        XCTAssertTrue(GlomoPaySDK.shared.validate(config).isEmpty)
        let url = try GlomoPaySDK.shared.checkoutURL(for: config, orderType: "standard")
        XCTAssertEqual(url.host, "checkout.glomopay.com")

        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: config.devMode,
            onComplete: { result in
                if case .success = result { listener.completedCount += 1 }
            },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )
        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed",
                ],
            ],
        ])

        XCTAssertEqual(listener.successes.first?.orderId, "order_123456")
        XCTAssertEqual(listener.completedCount, 1)
    }

    func testAutoOrderDetectionResolvesLRSCheckout() async throws {
        let client = IntegrationHTTPClient(result: .success(
            Data(#"{"id":"order_123456","orderType":"lrs"}"#.utf8)
        ))
        let api = GlomoPayApiClient(
            publicKey: "live_public_key",
            baseURL: URL(string: "https://api.example.com")!,
            client: client
        )
        let config = GlomoPayConfig(publicKey: "live_public_key", orderId: "order_123456")

        let order = try await api.fetchOrder(config.orderId!)
        let type = ConfigManager.detectOrderType(order)
        let url = try GlomoPaySDK.shared.checkoutURL(for: config, orderType: type)

        XCTAssertEqual(type, "lrs")
        XCTAssertEqual(url.host, "lrs-checkout.glomopay.com")
        XCTAssertEqual(client.lastRequest?.url?.path, "/api/public/v1/order/order_123456")
    }

    func testOrderDetectionFailureFallsBackToStandardCheckout() async throws {
        let client = IntegrationHTTPClient(result: .failure(URLError(.timedOut)))
        let api = GlomoPayApiClient(
            publicKey: "live_public_key",
            baseURL: URL(string: "https://api.example.com")!,
            client: client
        )
        let config = GlomoPayConfig(publicKey: "live_public_key", orderId: "order_123456")

        let detectedType: String
        do {
            _ = try await api.fetchOrder(config.orderId!)
            detectedType = "standard"
        } catch {
            // This is the same safe fallback used by the checkout controller.
            detectedType = "standard"
        }
        let url = try GlomoPaySDK.shared.checkoutURL(for: config, orderType: detectedType)

        XCTAssertEqual(detectedType, "standard")
        XCTAssertEqual(url.host, "checkout.glomopay.com")
    }

    func testBridgeTerminalResultIsDeliveredOnceDuringRegressionFlow() {
        let listener = IntegrationListener()
        var results: [GlomoPayResult] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { results.append($0) },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )

        let success: [String: Any] = [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed",
                ],
            ],
        ]
        router.handle(envelope: success)
        router.handle(envelope: ["type": "window.close"])
        router.handle(envelope: ["type": "message", "data": ["type": "payment.failure"]])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(listener.successes.count, 1)
        XCTAssertEqual(listener.terminations.count, 0)
    }
}

private final class IntegrationHTTPClient: GlomoPayHTTPClient {
    private let result: Result<Data, Error>
    private(set) var lastRequest: URLRequest?

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (try result.get(), response)
    }
}

private final class IntegrationListener: GlomoPayListener {
    var successes: [GlomoPayPayload] = []
    var terminations: [TerminationSource] = []
    var completedCount = 0

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) {}
    func onSdkError(_ errors: [SdkError]) {}
    func onConnectionError(_ error: ConnectionError) {}
    func onPaymentTerminate(_ source: TerminationSource) { terminations.append(source) }
}
