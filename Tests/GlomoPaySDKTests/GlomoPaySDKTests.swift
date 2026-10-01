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
            // The status travels; the response body does not. It used to be interpolated into
            // the error message, which carried an order payload into analytics and Sentry.
            XCTAssertEqual(error, .failedToLoadOrder(statusCode: 401))
            XCTAssertEqual(error.errorDescription, "Failed to load order. Status: 401")
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
    }

    /// There is no host event channel: these used to be forwarded to onEvent, which has been
    /// removed. The diagnostics live in analytics now, which is sanitised and does not depend on
    /// a merchant implementing anything.
    func testRoutesRedirectAndDependencyEventsToAnalyticsNotTheHost() {
        let listener = MockListener()
        let analytics = CapturingAnalyticsTracker()
        var openedURLs: [URL] = []
        let router = GlomoPayEventRouter(
            listener: listener,
            devMode: false,
            onComplete: { _ in },
            onWindowOpen: { openedURLs.append($0) },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )
        router.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        router.handle(envelope: ["type": "dependencies.failed_to_load", "message": "LRS data missing"])
        router.handle(envelope: ["type": "file.input", "accept": "image/*"])

        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://bank.example/3ds"])
        XCTAssertEqual(analytics.names, [
            AnalyticsEventName.redirectOpened,
            AnalyticsEventName.checkoutDependenciesFailed,
            AnalyticsEventName.fileUploadRequested,
        ])
    }

    func testBridgeReadyIsRoutedAsTheFinalOpenFunnelStep() {
        var readyCount = 0
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            onBridgeReady: { readyCount += 1 },
            analytics: NoOpAnalyticsTracker(),
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: ["type": "bridge.ready"])

        XCTAssertEqual(readyCount, 1)
    }

    func testTerminalResultWithNoListenerIsReportedNotDropped() {
        let analytics = CapturingAnalyticsTracker()
        var results: [GlomoPayResult] = []
        // No listener at all: the same situation as a host that let a weakly held one go.
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { results.append($0) },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [
            "type": "message",
            "data": [
                "type": "payment.success",
                "payload": [
                    "orderId": "order_123456",
                    "paymentId": "pay_123456",
                    "signature": "signed_payload",
                ],
            ],
        ])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(analytics.names.contains(AnalyticsEventName.listenerUnavailable))
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

    func testBridgeErrorWithNoListenerReportsUnavailable() {
        let analytics = CapturingAnalyticsTracker()
        let router = GlomoPayEventRouter(
            listener: nil,
            devMode: false,
            onComplete: { _ in },
            analytics: analytics,
            errorReporter: NoOpSDKErrorReporter()
        )

        router.handle(envelope: [:])

        XCTAssertTrue(analytics.names.contains(AnalyticsEventName.sdkError))
        XCTAssertTrue(analytics.names.contains(AnalyticsEventName.listenerUnavailable))
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
    var journeys: [GlomoPayUserJourneyPayload] = []
    var successes: [GlomoPayPayload] = []
    var failures: [GlomoPayPayload] = []
    var errors: [SdkError] = []

    func onPaymentSuccess(_ payload: GlomoPayPayload) { successes.append(payload) }
    func onPaymentFailure(_ payload: GlomoPayPayload) { failures.append(payload) }
    func onSdkError(_ errors: [SdkError]) { self.errors.append(contentsOf: errors) }
    func onUserJourneyCompleted(_ payload: GlomoPayUserJourneyPayload) { journeys.append(payload) }
    func onConnectionError(_ error: ConnectionError) {}
    func onPaymentTerminate(_ source: TerminationSource) {}
}

private final class CapturingAnalyticsTracker: AnalyticsTracking {
    var names: [String] = []
    func track(_ event: String, properties: [String: Any?]) { names.append(event) }
    func updateFlowType(_ flowType: String) {}
    func updateCheckoutURL(_ url: URL) {}
}
