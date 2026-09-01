import Foundation
import Network

struct IOSNetworkPathSnapshot {
    let isSatisfied: Bool
    let usesWiFi: Bool
    let usesCellular: Bool
}

protocol IOSNetworkPathMonitoring: AnyObject {
    var updateHandler: ((IOSNetworkPathSnapshot) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

final class IOSNetworkPathSnapshotCollector {
    private let monitor: IOSNetworkPathMonitoring
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var completion: (([String: Any?]) -> Void)?
    private var isFinished = false

    init(
        monitor: IOSNetworkPathMonitoring,
        queue: DispatchQueue = DispatchQueue(label: "com.glomopay.sdk.ios.network-snapshot")
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    func collect(
        timeout: TimeInterval = 0.25,
        completion: @escaping ([String: Any?]) -> Void
    ) {
        lock.lock()
        guard self.completion == nil, !isFinished else {
            lock.unlock()
            return
        }
        self.completion = completion
        lock.unlock()

        monitor.updateHandler = { [self] snapshot in
            finish(with: snapshot.isSatisfied ? snapshot : nil)
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            finish(with: nil)
        }
    }

    private func finish(with snapshot: IOSNetworkPathSnapshot?) {
        lock.lock()
        guard !isFinished, let completion else {
            lock.unlock()
            return
        }
        isFinished = true
        self.completion = nil
        lock.unlock()

        monitor.updateHandler = nil
        monitor.cancel()
        completion([
            "$wifi_enabled": snapshot?.usesWiFi,
            "$cellular_enabled": snapshot?.usesCellular,
        ])
    }

    deinit {
        monitor.updateHandler = nil
        monitor.cancel()
    }
}

private final class NWPathAnalyticsMonitor: IOSNetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    var updateHandler: ((IOSNetworkPathSnapshot) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateHandler?(IOSNetworkPathSnapshot(
                isSatisfied: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesCellular: path.usesInterfaceType(.cellular)
            ))
        }
    }

    func start(queue: DispatchQueue) {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

#if canImport(UIKit)
import UIKit

enum IOSAnalyticsProperties {
    static func makeNetworkSnapshotCollector() -> IOSNetworkPathSnapshotCollector {
        IOSNetworkPathSnapshotCollector(monitor: NWPathAnalyticsMonitor())
    }

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
            "$lib_version": GlomoPaySDKBuild.version,
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
