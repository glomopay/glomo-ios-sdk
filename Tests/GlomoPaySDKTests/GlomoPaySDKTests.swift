import XCTest
@testable import GlomoPaySDK

final class GlomoPaySDKTests: XCTestCase {
    func testBuildsStandardCheckoutURL() throws {
        let config = GlomoPayConfig(publicKey: "test_123456", orderId: "order_123456")
        let url = try GlomoPaySDK.shared.checkoutURL(for: config)
        XCTAssertEqual(url.host, "checkout.glomopay.com")
        XCTAssertTrue(url.absoluteString.contains("mode=mock"))
    }

    func testBuildsLRSCheckoutURL() throws {
        let config = GlomoPayConfig(publicKey: "live_123456", orderId: "order_123456")
        let url = try GlomoPaySDK.shared.checkoutURL(for: config, orderType: "lrs")
        XCTAssertEqual(url.host, "lrs-checkout.glomopay.com")
    }

    func testRejectsMissingIdentifier() {
        let config = GlomoPayConfig(publicKey: "test_123456")
        XCTAssertFalse(GlomoPaySDK.shared.validate(config).isEmpty)
    }

    func testDetectsLRSOrder() {
        XCTAssertEqual(ConfigManager.detectOrderType(["lrs": ["enabled": true]]), "lrs")
        XCTAssertEqual(ConfigManager.detectOrderType(["id": "order_1"]), "standard")
    }

    func testFetchOrderSendsFlutterCompatibleRequestAndParsesJSON() async throws {
        let client = MockHTTPClient(
            data: Data(#"{"id":"order_123456","orderType":"lrs"}"#.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
        let api = GlomoPayApiClient(
            publicKey: "test_public_key",
            baseURL: URL(string: "https://api.example.com")!,
            client: client
        )

        let order = try await api.fetchOrder("order_123456")

        XCTAssertEqual(order["orderType"] as? String, "lrs")
        XCTAssertEqual(client.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(client.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test_public_key")
        XCTAssertEqual(client.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(client.lastRequest?.url?.path, "/api/public/v1/order/order_123456")
    }

    func testFetchOrderWrapsNon200AsNetworkErrorLikeFlutter() async {
        let client = MockHTTPClient(
            data: Data(#"{"message":"unauthorized"}"#.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://api.example.com")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
        )
        let api = GlomoPayApiClient(
            publicKey: "test_public_key",
            baseURL: URL(string: "https://api.example.com")!,
            client: client
        )

        do {
            _ = try await api.fetchOrder("order_123456")
            XCTFail("Expected API error")
        } catch let error as GlomoPayAPIError {
            guard case let .network(message) = error else {
                return XCTFail("Expected network-wrapped API error")
            }
            XCTAssertTrue(message.contains("Status: 401"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapsTimeoutAsRecoverableConnectionError() {
        let error = ConnectionError.fromWebResourceError(
            description: "The request timed out.",
            errorCode: NSURLErrorTimedOut
        )
        XCTAssertEqual(error.type, .timeout)
        XCTAssertTrue(error.isRecoverable)
    }

    func testMapsServerErrorAsRecoverableConnectionError() {
        let error = ConnectionError.fromHTTPStatus(503)
        XCTAssertEqual(error.type, .httpServerError)
        XCTAssertTrue(error.isRecoverable)
        XCTAssertEqual(error.message, "Service Unavailable")
    }

    func testRoutesSuccessAndDeliversTerminalResultOnce() {
        let listener = MockListener()
        var results: [GlomoPayResult] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { results.append($0) },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )
        let event: [String: Any] = [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed_payload",
                ],
            ],
        ]

        router.handle(envelope: event)
        router.handle(envelope: event)

        XCTAssertEqual(listener.successes.count, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(listener.events.first?.name, "payment.success")
    }

    func testRoutesFailureAndCancellationEvents() {
        let listener = MockListener()
        var results: [GlomoPayResult] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { results.append($0) },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )
        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.failure",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed_payload",
                ],
            ],
        ])

        XCTAssertEqual(listener.failures.count, 1)
        XCTAssertEqual(results.count, 1)

        let cancellationListener = MockListener()
        var cancellationResults: [GlomoPayResult] = []
        let cancellationRouter = GlomoPayEventRouter(
            listener: cancellationListener,
            devMode: false,
            onComplete: { cancellationResults.append($0) },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )
        cancellationRouter.handle(envelope: ["type": "window.close"])
        XCTAssertEqual(cancellationResults.count, 0)
        XCTAssertEqual(cancellationListener.events.first?.name, "redirect.completed")
    }

    func testRoutesRedirectAndDependencyEvents() {
        let listener = MockListener()
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )
        router.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        router.handle(envelope: ["type": "dependencies.failed_to_load", "message": "LRS data missing"])
        router.handle(envelope: ["type": "file.input", "accept": "image/*"])

        XCTAssertEqual(listener.events.map(\.name), [
            "redirect.started",
            "checkout.dependencies_failed",
            "file.requested",
        ])
    }

    func testMalformedBridgeMessageBecomesSdkError() {
        let listener = MockListener()
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )
        router.handle(body: "not-json")
        XCTAssertEqual(listener.errors.count, 1)
        XCTAssertEqual(listener.errors.first?.type, .unknown)
    }
}

private final class MockHTTPClient: GlomoPayHTTPClient {
    let data: Data
    let response: URLResponse
    private(set) var lastRequest: URLRequest?

    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return (data, response)
    }
}

private final class MockListener: GlomoPayListener {
    struct Event {
        let name: String
        let payload: [String: Any]
    }

    var successes: [GlomoPayPayload] = []
    var failures: [GlomoPayPayload] = []
    var errors: [SdkError] = []
    var events: [Event] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) { failures.append(payload) }
    func onSdkError(_ errors: [SdkError]) { self.errors.append(contentsOf: errors) }
    func onConnectionError(_ error: ConnectionError) {}
    func onPaymentTerminate(_ source: TerminationSource) {}
    func onEvent(name: String, payload: [String: Any]) { events.append(Event(name: name, payload: payload)) }
}
