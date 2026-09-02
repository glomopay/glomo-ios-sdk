import XCTest
@testable import GlomoPaySDK

final class IOSNetworkPathSnapshotCollectorTests: XCTestCase {
    func testSatisfiedWiFiPathReturnsBooleansAndCancelsMonitor() {
        let monitor = FakeNetworkPathMonitor()
        let collector = IOSNetworkPathSnapshotCollector(monitor: monitor)
        let completed = expectation(description: "network snapshot")

        collector.collect(timeout: 1) { properties in
            XCTAssertEqual(properties["$wifi_enabled"] as? Bool, true)
            XCTAssertEqual(properties["$cellular_enabled"] as? Bool, false)
            completed.fulfill()
        }
        monitor.send(isSatisfied: true, usesWiFi: true, usesCellular: false)

        wait(for: [completed], timeout: 1)
        XCTAssertTrue(monitor.didStart)
        XCTAssertTrue(monitor.didCancel)
    }

    func testUnsatisfiedPathReturnsNilValues() {
        let monitor = FakeNetworkPathMonitor()
        let collector = IOSNetworkPathSnapshotCollector(monitor: monitor)
        let completed = expectation(description: "network snapshot")

        collector.collect(timeout: 1) { properties in
            XCTAssertNil(properties["$wifi_enabled"] as? Bool)
            XCTAssertNil(properties["$cellular_enabled"] as? Bool)
            completed.fulfill()
        }
        monitor.send(isSatisfied: false, usesWiFi: false, usesCellular: false)

        wait(for: [completed], timeout: 1)
        XCTAssertTrue(monitor.didCancel)
    }

    func testSatisfiedCellularPathReturnsCellularState() {
        let monitor = FakeNetworkPathMonitor()
        let collector = IOSNetworkPathSnapshotCollector(monitor: monitor)
        let completed = expectation(description: "cellular snapshot")

        collector.collect(timeout: 1) { properties in
            XCTAssertEqual(properties["$wifi_enabled"] as? Bool, false)
            XCTAssertEqual(properties["$cellular_enabled"] as? Bool, true)
            completed.fulfill()
        }
        monitor.send(isSatisfied: true, usesWiFi: false, usesCellular: true)

        wait(for: [completed], timeout: 1)
        XCTAssertTrue(monitor.didCancel)
    }

    func testTimeoutReturnsNilValuesAndCancelsMonitor() {
        let monitor = FakeNetworkPathMonitor()
        let collector = IOSNetworkPathSnapshotCollector(monitor: monitor)
        let completed = expectation(description: "network timeout")

        collector.collect(timeout: 0.01) { properties in
            XCTAssertNil(properties["$wifi_enabled"] as? Bool)
            XCTAssertNil(properties["$cellular_enabled"] as? Bool)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertTrue(monitor.didCancel)
    }
}

private final class FakeNetworkPathMonitor: IOSNetworkPathMonitoring {
    var updateHandler: ((IOSNetworkPathSnapshot) -> Void)?
    private(set) var didStart = false
    private(set) var didCancel = false

    func start(queue: DispatchQueue) {
        didStart = true
    }

    func cancel() {
        didCancel = true
    }

    func send(isSatisfied: Bool, usesWiFi: Bool, usesCellular: Bool) {
        updateHandler?(IOSNetworkPathSnapshot(
            isSatisfied: isSatisfied,
            usesWiFi: usesWiFi,
            usesCellular: usesCellular
        ))
    }
}
