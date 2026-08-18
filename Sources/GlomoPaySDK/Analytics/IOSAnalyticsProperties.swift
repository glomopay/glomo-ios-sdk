#if canImport(UIKit)
import Foundation
import UIKit

enum IOSAnalyticsProperties {
    static func collect(bundle: Bundle = .main, screen: UIScreen = .main) -> [String: Any?] {
        let info = bundle.infoDictionary ?? [:]
        let bounds = screen.nativeBounds
        let model = hardwareModel()
        return [
            "device_os_version": UIDevice.current.systemVersion,
            "$model": model,
            "$device": UIDevice.current.model,
            "$os": "iOS",
            "$os_version": UIDevice.current.systemVersion,
            "$manufacturer": "Apple",
            "$brand": "Apple",
            "$device_type": "ios",
            "$screen_width": Int(bounds.width),
            "$screen_height": Int(bounds.height),
            "$screen_density": screen.scale,
            "$app_version_string": info["CFBundleShortVersionString"] as? String,
            "$app_namespace": bundle.bundleIdentifier,
            "$app_build_number": info["CFBundleVersion"] as? String,
            "$app_name": (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            "$locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "$lib_version": "1.0.0",
            "mp_lib": "glomo-ios-sdk",
            "$wifi_enabled": nil,
            "$cellular_enabled": nil,
        ]
    }

    private static func hardwareModel() -> String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
#endif
