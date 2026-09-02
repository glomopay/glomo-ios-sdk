enum ComplianceAnalyticsProperties {
    static func make(result: DeviceComplianceResult, devMode: Bool) -> [String: Any?] {
        let sensitiveChecksSkipped = devMode || result.checksSkipped
        return [
            "is_compliant": sensitiveChecksSkipped ? nil : result.isCompliant,
            "is_jailbroken": sensitiveChecksSkipped ? nil : result.isJailbroken,
            "is_emulator": sensitiveChecksSkipped ? nil : result.isSimulator,
            "is_developer_mode_enabled": sensitiveChecksSkipped ? nil : result.isDeveloperModeEnabled,
            "is_debugger_attached": result.isDebuggerAttached,
            "compliance_checks_skipped": result.checksSkipped,
            "is_usb_debugging_enabled": nil,
            "has_test_keys": nil,
        ]
    }
}
