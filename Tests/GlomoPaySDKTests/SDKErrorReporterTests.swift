import XCTest
@testable import GlomoPaySDK

final class SDKErrorReporterTests: XCTestCase {
    func testTerminalFlusherFlushesReporterOffMainThread() {
        let expectation = expectation(description: "Reporter flushed")
        let reporter = FlushRecordingErrorReporter(expectation: expectation)

        SDKErrorReporterTerminalFlusher.flush(reporter)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(reporter.timeout, SDKErrorReporterTerminalFlusher.timeout)
        XCTAssertFalse(reporter.wasCalledOnMainThread)
    }

    func testNoOpReporterAcceptsFlush() {
        NoOpSDKErrorReporter().flush(timeout: 1)
    }
}

private final class FlushRecordingErrorReporter: SDKErrorReporting, @unchecked Sendable {
    private let expectation: XCTestExpectation
    private let lock = NSLock()
    private var recordedTimeout: TimeInterval?
    private var recordedMainThreadState = true

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var timeout: TimeInterval? {
        lock.withLock { recordedTimeout }
    }

    var wasCalledOnMainThread: Bool {
        lock.withLock { recordedMainThreadState }
    }

    func updateFlowType(_ flowType: String) {}
    func addBreadcrumb(category: String, message: String, data: [String: Any?]) {}
    func capture(operation: String, error: Error, context: [String: Any?]) {}

    func flush(timeout: TimeInterval) {
        lock.withLock {
            recordedTimeout = timeout
            recordedMainThreadState = Thread.isMainThread
        }
        expectation.fulfill()
    }
}
