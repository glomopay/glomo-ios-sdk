import XCTest

/// The published manifest is what every merchant compiles. It must not read the build
/// environment (SwiftPM evaluates manifests with the builder's environment, so an environment
/// read lets any build switch behaviour) and must not define the internal-build condition.
final class PackageManifestTests: XCTestCase {
    func testManifestReadsNoEnvironmentAndNeverDefinesTheInternalBuildCondition() throws {
        let manifest = try String(contentsOf: Self.manifestURL, encoding: .utf8)
        let code = manifest
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(manifest.contains("ProcessInfo"), "Package.swift must not use ProcessInfo")
        for forbidden in ["getenv", "environment[", "import Foundation"] {
            XCTAssertFalse(code.contains(forbidden), "Package.swift must not contain \(forbidden)")
        }
        XCTAssertNil(
            code.range(of: #"\.define\(\s*"GLOMO_INTERNAL_BUILD""#, options: .regularExpression),
            "Package.swift must not define GLOMO_INTERNAL_BUILD"
        )
        XCTAssertFalse(code.contains("-DGLOMO_INTERNAL_BUILD"), "Package.swift must not pass -DGLOMO_INTERNAL_BUILD")
        XCTAssertFalse(code.contains("unsafeFlags"), "Package.swift must not pass unsafe flags")
    }

    /// The repository root, found from this file's location at compile time. The simulator
    /// shares the host file system, so this works on the iOS job too.
    private static var manifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
