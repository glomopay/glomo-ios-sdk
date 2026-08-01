import XCTest
@testable import GlomoPaySDK

final class AnalyticsTests: XCTestCase {
    func testAnalyticsUsesFlutterCompatibleEventAndContext() {
        let transport = AnalyticsTestTransport()
        let sent = expectation(description: "analytics event sent")
        transport.onSend = { sent.fulfill() }

        let analytics = GlomoPayAnalytics(devMode: true, transport: transport)
        analytics.setCheckoutContext(
            orderID: "order_test",
            publicKey: "test_public_key",
            checkoutType: "lrs",
            mockMode: true
        )
        analytics.trackStartAttempt()

        wait(for: [sent], timeout: 1)

        XCTAssertEqual(transport.events.count, 1)
        XCTAssertEqual(transport.events.first?.name, GlomoPayAnalyticsEvents.startAttempt)
        XCTAssertEqual(transport.events.first?.properties["platform"] as? String, "ios")
        XCTAssertEqual(transport.events.first?.properties["checkout_type"] as? String, "lrs")
        XCTAssertEqual(transport.events.first?.properties["order_id"] as? String, "order_test")
        XCTAssertEqual(transport.events.first?.properties["mock_mode"] as? Bool, true)
    }

    func testDisabledAnalyticsDoesNotSendEvents() {
        let transport = AnalyticsTestTransport()
        let notSent = expectation(description: "analytics event is not sent")
        notSent.isInverted = true
        transport.onSend = { notSent.fulfill() }

        let analytics = GlomoPayAnalytics(devMode: false, enabled: false, transport: transport)
        analytics.trackEvent("Should Not Be Sent")

        wait(for: [notSent], timeout: 0.2)
        XCTAssertTrue(transport.events.isEmpty)
    }
}

private final class AnalyticsTestTransport: GlomoPayAnalyticsTransport {
    struct Event {
        let name: String
        let properties: [String: Any]
        let context: [String: Any]
    }

    private let lock = NSLock()
    private(set) var events: [Event] = []
    var onSend: (() -> Void)?

    func send(eventName: String, properties: [String: Any], context: [String: Any]) {
        lock.lock()
        events.append(Event(name: eventName, properties: properties, context: context))
        lock.unlock()
        onSend?()
    }
}
