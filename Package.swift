// swift-tools-version: 5.9
import PackageDescription

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
            ]
        ),
        .testTarget(
            name: "GlomoPaySDKTests",
            dependencies: ["GlomoPaySDK"],
            path: "Tests/GlomoPaySDKTests"
        ),
    ]
)
