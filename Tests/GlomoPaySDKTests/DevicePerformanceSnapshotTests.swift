import XCTest
@testable import GlomoPaySDK

final class DevicePerformanceSnapshotTests: XCTestCase {
    func testCollectsMixpanelFriendlyPerformanceProperties() {
        let reader = FakeDevicePerformanceReader(
            batteryLevel: 0.42,
            batteryState: .charging,
            isLowPowerModeEnabled: true,
            thermalState: .serious,
            totalMemoryBytes: 8_000_000_000,
            availableMemoryBytes: 120_000_000,
            usedMemoryBytes: 450_000_000,
            activeProcessorCount: 6
        )

        let properties = DevicePerformanceSnapshot.collect(from: reader)

        XCTAssertEqual(properties["perf_snapshot_at"] as? String, "sdk_initialized")
        XCTAssertEqual(properties["battery_level_percent"] as? Int, 42)
        XCTAssertEqual(properties["battery_state"] as? String, "charging")
        XCTAssertEqual(properties["is_low_power_mode"] as? Bool, true)
        XCTAssertEqual(properties["thermal_state"] as? String, "serious")
        XCTAssertEqual(properties["ram_total_bytes"] as? Int64, 8_000_000_000)
        XCTAssertEqual(properties["ram_available_bytes"] as? Int64, 120_000_000)
        XCTAssertEqual(properties["ram_used_bytes"] as? Int64, 450_000_000)
        XCTAssertEqual(properties["processor_count"] as? Int, 6)
        XCTAssertNil(properties["is_low_memory"] as? Bool)
    }

    func testUnknownBatteryLevelIsNullInsteadOfNegativeOrZero() {
        let reader = FakeDevicePerformanceReader(batteryLevel: -1)

        let properties = DevicePerformanceSnapshot.collect(from: reader)

        XCTAssertNil(properties["battery_level_percent"] as? Int)
        XCTAssertEqual(properties["battery_state"] as? String, "unknown")
    }

    func testCollectorEnablesMonitoringBeforeCollectionAndRestoresItWhenStopped() {
        let reader = FakeDevicePerformanceReader(
            isBatteryMonitoringEnabled: false,
            batteryLevel: 0.5
        )
        let collector = DevicePerformanceSnapshotCollector(reader: reader)

        XCTAssertTrue(reader.isBatteryMonitoringEnabled)
        XCTAssertEqual(reader.batteryMonitoringChanges, [true])

        _ = collector.collect()
        XCTAssertEqual(reader.batteryMonitoringChanges, [true])

        collector.restoreBatteryMonitoring()

        XCTAssertFalse(reader.isBatteryMonitoringEnabled)
        XCTAssertEqual(reader.batteryMonitoringChanges, [true, false])
    }

    func testCollectorDoesNotModifyMonitoringThatWasAlreadyEnabledByHost() {
        let reader = FakeDevicePerformanceReader(
            isBatteryMonitoringEnabled: true,
            batteryLevel: 0.5
        )
        let collector = DevicePerformanceSnapshotCollector(reader: reader)

        _ = collector.collect()
        collector.restoreBatteryMonitoring()

        XCTAssertTrue(reader.isBatteryMonitoringEnabled)
        XCTAssertEqual(reader.batteryMonitoringChanges, [])
    }

    func testZeroAvailableMemoryIsReportedAsNull() {
        let reader = FakeDevicePerformanceReader(availableMemoryBytes: 0)

        let properties = DevicePerformanceSnapshot.collect(from: reader)

        XCTAssertNil(properties["ram_available_bytes"] as? Int64)
    }

    func testNullableValuesSurviveAnalyticsSanitization() {
        let reader = FakeDevicePerformanceReader(
            batteryLevel: -1,
            isLowPowerModeEnabled: nil,
            thermalState: nil,
            totalMemoryBytes: nil,
            availableMemoryBytes: nil,
            usedMemoryBytes: nil,
            activeProcessorCount: nil
        )

        let sanitized = AnalyticsSanitizer.properties(
            DevicePerformanceSnapshot.collect(from: reader)
        )

        XCTAssertTrue(sanitized["battery_level_percent"] is NSNull)
        XCTAssertTrue(sanitized["thermal_state"] is NSNull)
        XCTAssertTrue(sanitized["ram_available_bytes"] is NSNull)
        XCTAssertTrue(sanitized["ram_used_bytes"] is NSNull)
        XCTAssertTrue(sanitized["processor_count"] is NSNull)
    }
}

private final class FakeDevicePerformanceReader: DevicePerformanceReading {
    private var monitoringEnabled: Bool
    private(set) var batteryMonitoringChanges: [Bool] = []
    let batteryLevel: Float
    let batteryState: DevicePerformanceBatteryState
    let isLowPowerModeEnabled: Bool?
    let thermalState: DevicePerformanceThermalState?
    let totalMemoryBytes: Int64?
    let availableMemoryBytes: Int64?
    let usedMemoryBytes: Int64?
    let activeProcessorCount: Int?

    var isBatteryMonitoringEnabled: Bool {
        get { monitoringEnabled }
        set {
            monitoringEnabled = newValue
            batteryMonitoringChanges.append(newValue)
        }
    }

    init(
        isBatteryMonitoringEnabled: Bool = false,
        batteryLevel: Float = -1,
        batteryState: DevicePerformanceBatteryState = .unknown,
        isLowPowerModeEnabled: Bool? = false,
        thermalState: DevicePerformanceThermalState? = .nominal,
        totalMemoryBytes: Int64? = 4_000_000_000,
        availableMemoryBytes: Int64? = 500_000_000,
        usedMemoryBytes: Int64? = 250_000_000,
        activeProcessorCount: Int? = 4
    ) {
        monitoringEnabled = isBatteryMonitoringEnabled
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.usedMemoryBytes = usedMemoryBytes
        self.activeProcessorCount = activeProcessorCount
    }
}
