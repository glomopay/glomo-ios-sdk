// swift-tools-version: 5.9
import PackageDescription

// This manifest must stay a constant: it reads nothing from the build environment and defines
// no compilation conditions. The internal-build condition (see SDKBuildFlags.swift) is never set
// here; an internal build passes it on its own command line, as CONTRIBUTING.md describes.
// `PackageManifestTests` fails if this file reads the environment or defines that condition.

let package = Package(
    name: "glomo-ios-sdk",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        // macOS exists only so `swift test` can run on a Mac host.
        .macOS(.v12),
    ],
    products: [
        .library(name: "glomo-ios-sdk", targets: ["GlomoPaySDK"]),
    ],
    targets: [
        .target(
            name: "GlomoPaySDK",
            path: "Sources/GlomoPaySDK",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy"),
                .process("Resources/GlomoPayTelemetryConfiguration.plist"),
                .process("Resources/en.lproj/GlomoPayLocalizable.strings"),
            ]
        ),
        .testTarget(
            name: "GlomoPaySDKTests",
            dependencies: ["GlomoPaySDK"],
            path: "Tests/GlomoPaySDKTests"
        ),
    ]
)
