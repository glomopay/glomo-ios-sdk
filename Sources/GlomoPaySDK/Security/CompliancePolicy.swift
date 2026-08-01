import Foundation

public enum CompliancePolicy {
    /// Matches Flutter/Kotlin: only live, non-dev checkout sessions are strict.
    public static func requiresStrictCheck(_ config: GlomoPayConfig) -> Bool {
        ConfigManager.getMode(config.publicKey) == "live" && !config.devMode
    }
}
