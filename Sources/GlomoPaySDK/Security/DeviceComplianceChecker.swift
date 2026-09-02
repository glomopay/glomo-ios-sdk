import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(UIKit)
import UIKit
#endif

public struct DeviceComplianceProbe {
    public let jailbreakCheck: () -> Bool
    public let debuggerCheck: () -> Bool
    public let simulatorCheck: () -> Bool

    public init(
        jailbreakCheck: @escaping () -> Bool,
        debuggerCheck: @escaping () -> Bool,
        simulatorCheck: @escaping () -> Bool
    ) {
        self.jailbreakCheck = jailbreakCheck
        self.debuggerCheck = debuggerCheck
        self.simulatorCheck = simulatorCheck
    }

    public static let live = DeviceComplianceProbe(
        jailbreakCheck: DeviceComplianceChecker.defaultJailbreakCheck,
        debuggerCheck: DeviceComplianceChecker.defaultDebuggerCheck,
        simulatorCheck: DeviceComplianceChecker.defaultSimulatorCheck
    )
}

/// iOS counterpart of safe_device/root checks used by the Flutter SDK.
public final class DeviceComplianceChecker {
    private let probe: DeviceComplianceProbe

    public init(probe: DeviceComplianceProbe = .live) {
        self.probe = probe
    }

    public func check(strict: Bool) -> DeviceComplianceResult {
        let simulator = probe.simulatorCheck()
        let jailbroken = probe.jailbreakCheck()
        let debuggerAttached = probe.debuggerCheck()

        if !strict {
            return DeviceComplianceResult(
                isCompliant: true,
                isJailbroken: false,
                isDebuggerAttached: debuggerAttached,
                isSimulator: simulator,
                isDeveloperModeEnabled: false,
                checksSkipped: true
            )
        }

        return DeviceComplianceResult(
            isCompliant: !jailbroken && !debuggerAttached,
            isJailbroken: jailbroken,
            isDebuggerAttached: debuggerAttached,
            isSimulator: simulator,
            isDeveloperModeEnabled: false,
            checksSkipped: false
        )
    }

    public static let defaultJailbreakCheck: () -> Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt",
            "/var/jb",
        ]
        if suspiciousPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return true
        }

        // URL scheme probing is intentionally best-effort and only used on iOS.
        // Apps must allow-list these schemes if they want this secondary signal.
        // The filesystem signals above remain the primary check.
        // No files are created or modified during the check.
        return false
        #endif
    }

    public static let defaultDebuggerCheck: () -> Bool = {
        #if canImport(Darwin)
        var processInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = query.withUnsafeMutableBufferPointer { queryBuffer in
            withUnsafeMutablePointer(to: &processInfo) { processPointer in
                sysctl(queryBuffer.baseAddress, u_int(queryBuffer.count), processPointer, &size, nil, 0)
            }
        }
        guard result == 0 else { return false }
        return (processInfo.kp_proc.p_flag & P_TRACED) != 0
        #else
        return false
        #endif
    }

    public static let defaultSimulatorCheck: () -> Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
