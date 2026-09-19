import Foundation

/// Advanced build flags. There is no merchant-facing way to set any of them.
enum SDKBuildFlags {
    /// Enables verbose logging and relaxes the jailbroken/debugger device block on live
    /// checkouts, so it must never be set on a build that ships to merchants.
    ///
    /// There is no baked-in value to override: absent means false, and only the compile-time
    /// definition of `GLOMO_INTERNAL_BUILD` turns it on, so a typo or a missing flag both fail
    /// closed. The SDK is source-distributed through SPM and CocoaPods, so the flag is compiled
    /// from Glomo-controlled manifests - a merchant cannot set it without editing the package
    /// manifest or podspec.
    ///
    /// It rides on every analytics event as `dev_mode`, which is how a build that shipped with it
    /// enabled is detected after the fact. It must never gate analytics or error reporting:
    /// those are decided by Mixpanel token and Sentry DSN presence alone.
    #if GLOMO_INTERNAL_BUILD
    static let internalBuild = true
    #else
    static let internalBuild = false
    #endif
}
