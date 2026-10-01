import Foundation

/// Build flags. There is no runtime or configuration API for any of them.
enum SDKBuildFlags {
    /// Enables verbose logging and relaxes the jailbroken/debugger device block on live
    /// checkouts, so it must never be set on a build that ships to merchants.
    ///
    /// It is on only when the Swift compilation condition `GLOMO_INTERNAL_BUILD` is defined, and
    /// the published package never defines it: `Package.swift` reads nothing from the build
    /// environment and declares no conditions. Glomo's internal builds pass it explicitly, e.g.
    /// `swift test -Xswiftc -DGLOMO_INTERNAL_BUILD`.
    ///
    /// This is not a security boundary. The SDK is source-distributed, and whoever compiles it
    /// can define any condition, this one included. What keeps it honest is visibility: it is
    /// reported as `dev_mode` on every Mixpanel event and every Sentry event, so a build that
    /// enables it shows up. It must never gate analytics or error reporting: those are decided by
    /// Mixpanel token and Sentry DSN presence alone.
    #if GLOMO_INTERNAL_BUILD
    static let internalBuild = true
    #else
    static let internalBuild = false
    #endif
}
