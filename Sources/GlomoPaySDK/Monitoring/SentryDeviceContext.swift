import Foundation

/// The Sentry `contexts` block: just enough to triage OS- and hardware-specific failures, such as
/// a WKWebView bug on one iOS version.
///
/// Non-PII only, and nothing the SDK's analytics does not already collect. It deliberately leaves
/// out the device name, identifierForVendor, advertising id, IP, locale, timezone, battery,
/// memory and view-controller names. `app` holds only the host app's version and build; its bundle
/// id and name are not sent.
///
/// Built from `ProcessInfo`, `uname` and `sysctl`, which are thread-safe, so it never touches
/// `UIDevice` or anything else that is main-thread only. The client builds it once, at init.
enum SentryDeviceContext {
    static func make(infoDictionary: [String: Any]?) -> [String: Any] {
        var contexts: [String: Any] = [
            "os": os(),
            "device": device(),
        ]
        var app: [String: Any] = [:]
        app["app_version"] = infoDictionary?["CFBundleShortVersionString"] as? String
        app["app_build"] = infoDictionary?["CFBundleVersion"] as? String
        if !app.isEmpty { contexts["app"] = app }
        return contexts
    }

    private static func os() -> [String: Any] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // Same shape as `UIDevice.systemVersion`, which analytics sends: "17.4", "17.4.1".
        var versionString = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { versionString += ".\(version.patchVersion)" }
        var os: [String: Any] = ["name": osName, "version": versionString]
        os["build"] = sysctlString("kern.osversion")
        return os
    }

    private static func device() -> [String: Any] {
        var device: [String: Any] = ["simulator": isSimulator]
        let model = hardwareModel()
        device["model"] = model
        device["family"] = family(model: model)
        return device
    }

    private static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The hardware identifier analytics reports as `$model`, e.g. "iPhone15,2". A simulator's
    /// `uname` reports the host CPU, so the simulated model identifier is used there instead.
    private static func hardwareModel() -> String? {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? nil : machine
    }

    private static func family(model: String?) -> String {
        #if os(iOS)
        return model?.hasPrefix("iPad") == true ? "iPad" : "iOS"
        #else
        return osName
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}
