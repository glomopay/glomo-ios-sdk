// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Internal SDK builds only. Absent means false and only the literal "true" enables it, so a typo
// or a missing value both fail closed. It relaxes the jailbroken/debugger device block and turns
// on verbose logging, so it must never be set for a build that ships to merchants. Because the
// package is source-distributed, a merchant cannot set it without editing this manifest.
let internalBuild = ProcessInfo.processInfo.environment["GLOMO_INTERNAL_BUILD"] == "true"
let sdkSwiftSettings: [SwiftSetting] = internalBuild ? [.define("GLOMO_INTERNAL_BUILD")] : []

let package = Package(
    name: "glomo-ios-sdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "glomo-ios-sdk", targets: ["GlomoPaySDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "8.58.4"),
    ],
    targets: [
        .target(
            name: "GlomoPaySDK",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/GlomoPaySDK",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy"),
                .process("Resources/GlomoPayTelemetryConfiguration.plist"),
                .process("Resources/en.lproj/GlomoPayLocalizable.strings"),
            ],
            swiftSettings: sdkSwiftSettings
        ),
        .testTarget(
            name: "GlomoPaySDKTests",
            dependencies: ["GlomoPaySDK"],
            path: "Tests/GlomoPaySDKTests"
        ),
    ]
)
