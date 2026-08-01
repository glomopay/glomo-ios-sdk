import Foundation

public struct DeviceComplianceResult: Sendable, Equatable {
    public let isCompliant: Bool
    public let isJailbroken: Bool
    public let isDebuggerAttached: Bool
    public let isSimulator: Bool
    public let isDeveloperModeEnabled: Bool
    public let checksSkipped: Bool

    public init(
        isCompliant: Bool,
        isJailbroken: Bool,
        isDebuggerAttached: Bool,
        isSimulator: Bool,
        isDeveloperModeEnabled: Bool,
        checksSkipped: Bool
    ) {
        self.isCompliant = isCompliant
        self.isJailbroken = isJailbroken
        self.isDebuggerAttached = isDebuggerAttached
        self.isSimulator = isSimulator
        self.isDeveloperModeEnabled = isDeveloperModeEnabled
        self.checksSkipped = checksSkipped
    }
}
