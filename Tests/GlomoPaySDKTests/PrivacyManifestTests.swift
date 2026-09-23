import XCTest
@testable import GlomoPaySDK

final class PrivacyManifestTests: XCTestCase {
    func testManifestDeclaresLinkedCoarseLocationForIPAnalytics() throws {
        let manifest = try loadManifest()
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let byType = Dictionary(uniqueKeysWithValues: collected.compactMap { entry in
            (entry["NSPrivacyCollectedDataType"] as? String).map { ($0, entry) }
        })

        let coarseLocation = try XCTUnwrap(byType["NSPrivacyCollectedDataTypeCoarseLocation"])
        XCTAssertEqual(coarseLocation["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(coarseLocation["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(
            coarseLocation["NSPrivacyCollectedDataTypePurposes"] as? [String],
            ["NSPrivacyCollectedDataTypePurposeAnalytics"]
        )

        for type in [
            "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypePerformanceData",
        ] {
            XCTAssertEqual(byType[type]?["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        }
    }

    func testManifestDoesNotMisclassifyAnalyticsAsATTTracking() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
    }

    private func loadManifest() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
