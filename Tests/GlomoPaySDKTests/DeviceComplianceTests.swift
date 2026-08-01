import XCTest
@testable import GlomoPaySDK

final class DeviceComplianceTests: XCTestCase {
    func testLiveNonDevModeRequiresStrictChecks() {
        XCTAssertTrue(CompliancePolicy.requiresStrictCheck(
            GlomoPayConfig(publicKey: "live_public_key", orderId: "order_123456")
        ))
        XCTAssertFalse(CompliancePolicy.requiresStrictCheck(
            GlomoPayConfig(publicKey: "live_public_key", orderId: "order_123456", devMode: true)
        ))
        XCTAssertFalse(CompliancePolicy.requiresStrictCheck(
            GlomoPayConfig(publicKey: "test_public_key", orderId: "order_123456")
        ))
    }

    func testSkippedChecksAllowDevelopmentAndExposeDiagnostics() {
        let checker = DeviceComplianceChecker(probe: DeviceComplianceProbe(
            jailbreakCheck: { true },
            debuggerCheck: { true },
            simulatorCheck: { true }
        ))
        let result = checker.check(strict: false)
        XCTAssertTrue(result.isCompliant)
        XCTAssertTrue(result.isSimulator)
        XCTAssertTrue(result.checksSkipped)
        XCTAssertFalse(result.isJailbroken)
        XCTAssertFalse(result.isDebuggerAttached)
    }

    func testStrictChecksBlockJailbrokenDevice() {
        let checker = DeviceComplianceChecker(probe: DeviceComplianceProbe(
            jailbreakCheck: { true },
            debuggerCheck: { false },
            simulatorCheck: { false }
        ))
        let result = checker.check(strict: true)
        XCTAssertFalse(result.isCompliant)
        XCTAssertTrue(result.isJailbroken)
        XCTAssertFalse(result.isDebuggerAttached)
    }

    func testStrictChecksBlockAttachedDebugger() {
        let checker = DeviceComplianceChecker(probe: DeviceComplianceProbe(
            jailbreakCheck: { false },
            debuggerCheck: { true },
            simulatorCheck: { false }
        ))
        let result = checker.check(strict: true)
        XCTAssertFalse(result.isCompliant)
        XCTAssertFalse(result.isJailbroken)
        XCTAssertTrue(result.isDebuggerAttached)
    }

    func testStrictChecksAllowCleanDevice() {
        let checker = DeviceComplianceChecker(probe: DeviceComplianceProbe(
            jailbreakCheck: { false },
            debuggerCheck: { false },
            simulatorCheck: { false }
        ))
        XCTAssertTrue(checker.check(strict: true).isCompliant)
    }
}
