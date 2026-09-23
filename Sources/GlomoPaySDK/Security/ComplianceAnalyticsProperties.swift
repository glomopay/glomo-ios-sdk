enum ComplianceAnalyticsProperties {
    /// The internal-build flag deliberately does not appear here.
    ///
    /// It used to be OR-ed into `sensitiveChecksSkipped`, so the same flag that relaxed the
    /// jailbreak block also nulled `is_compliant`, `is_jailbroken` and `is_emulator` - the
    /// telemetry that would have revealed it was relaxed. Only an actually skipped check nulls
    /// them now; `dev_mode` rides on every event separately, which is how a build that shipped
    /// with the flag enabled is detected after the fact.
    static func make(result: DeviceComplianceResult) -> [String: Any?] {
        let sensitiveChecksSkipped = result.checksSkipped
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
