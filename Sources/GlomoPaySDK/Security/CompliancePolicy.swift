import Foundation

public enum CompliancePolicy {
    /// Only an SDK-owner internal build can relax live-device enforcement. There is no
    /// merchant-settable flag here any more: `devMode: true` with a live key used to skip the
    /// jailbreak and debugger block entirely, and the sample app shipped it enabled by default.
    public static func requiresStrictCheck(_ config: GlomoPayConfig) -> Bool {
        requiresStrictCheck(config, internalBuild: SDKBuildFlags.internalBuild)
    }

    static func requiresStrictCheck(_ config: GlomoPayConfig, internalBuild: Bool) -> Bool {
        ConfigManager.getMode(config.publicKey) == "live" && !internalBuild
    }
}
