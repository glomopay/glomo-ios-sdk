import Foundation

enum DevicePerformanceBatteryState: String {
    case unplugged
    case charging
    case full
    case unknown
}

enum DevicePerformanceThermalState: String {
    case nominal
    case fair
    case serious
    case critical
}

protocol DevicePerformanceReading: AnyObject {
    var isBatteryMonitoringEnabled: Bool { get set }
    var batteryLevel: Float { get }
    var batteryState: DevicePerformanceBatteryState { get }
    var isLowPowerModeEnabled: Bool? { get }
    var thermalState: DevicePerformanceThermalState? { get }
    var totalMemoryBytes: Int64? { get }
    var availableMemoryBytes: Int64? { get }
    var usedMemoryBytes: Int64? { get }
    var activeProcessorCount: Int? { get }
}

final class DevicePerformanceSnapshotCollector {
    private let reader: DevicePerformanceReading
    private let shouldRestoreBatteryMonitoring: Bool
    private var didRestoreBatteryMonitoring = false

    init(reader: DevicePerformanceReading) {
        self.reader = reader
        shouldRestoreBatteryMonitoring = !reader.isBatteryMonitoringEnabled
        if shouldRestoreBatteryMonitoring {
            reader.isBatteryMonitoringEnabled = true
        }
    }

    func collect() -> [String: Any?] {
        DevicePerformanceSnapshot.collect(from: reader)
    }

    func restoreBatteryMonitoring() {
        guard shouldRestoreBatteryMonitoring, !didRestoreBatteryMonitoring else { return }
        didRestoreBatteryMonitoring = true
        reader.isBatteryMonitoringEnabled = false
    }

    deinit {
        restoreBatteryMonitoring()
    }
}

enum DevicePerformanceSnapshot {
    #if canImport(UIKit)
    static func makeCollector() -> DevicePerformanceSnapshotCollector {
        DevicePerformanceSnapshotCollector(reader: IOSDevicePerformanceReader())
    }
    #endif

    static func collect(from reader: DevicePerformanceReading) -> [String: Any?] {
        let level = reader.batteryLevel
        let batteryLevelPercent: Int? = (0...1).contains(level)
            ? Int((level * 100).rounded())
            : nil
        let availableMemoryBytes = reader.availableMemoryBytes.flatMap { value in
            value == 0 ? nil : value
        }

        return [
            "perf_snapshot_at": "sdk_initialized",
            "battery_level_percent": batteryLevelPercent,
            "battery_state": reader.batteryState.rawValue,
            "is_low_power_mode": reader.isLowPowerModeEnabled,
            "thermal_state": reader.thermalState?.rawValue,
            "ram_total_bytes": reader.totalMemoryBytes,
            "ram_available_bytes": availableMemoryBytes,
            "ram_used_bytes": reader.usedMemoryBytes,
            "is_low_memory": nil,
            "processor_count": reader.activeProcessorCount,
        ]
    }

    static let emptyProperties: [String: Any?] = [
        "perf_snapshot_at": "sdk_initialized",
        "battery_level_percent": nil,
        "battery_state": nil,
        "is_low_power_mode": nil,
        "thermal_state": nil,
        "ram_total_bytes": nil,
        "ram_available_bytes": nil,
        "ram_used_bytes": nil,
        "is_low_memory": nil,
        "processor_count": nil,
    ]
}

#if canImport(UIKit)
import Darwin
import UIKit

private final class IOSDevicePerformanceReader: DevicePerformanceReading {
    private let device = UIDevice.current
    private let processInfo = ProcessInfo.processInfo

    var isBatteryMonitoringEnabled: Bool {
        get { device.isBatteryMonitoringEnabled }
        set { device.isBatteryMonitoringEnabled = newValue }
    }

    var batteryLevel: Float { device.batteryLevel }

    var batteryState: DevicePerformanceBatteryState {
        switch device.batteryState {
        case .unplugged: return .unplugged
        case .charging: return .charging
        case .full: return .full
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    var isLowPowerModeEnabled: Bool? { processInfo.isLowPowerModeEnabled }

    var thermalState: DevicePerformanceThermalState? {
        switch processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }

    var totalMemoryBytes: Int64? {
        Int64(exactly: processInfo.physicalMemory)
    }

    var availableMemoryBytes: Int64? {
        let availableMemory = os_proc_available_memory()
        guard availableMemory != 0 else { return nil }
        return Int64(exactly: availableMemory)
    }

    var usedMemoryBytes: Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(exactly: info.phys_footprint)
    }

    var activeProcessorCount: Int? { processInfo.activeProcessorCount }
}
#endif
