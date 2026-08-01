// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlomoPaySDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "GlomoPaySDK", targets: ["GlomoPaySDK"]),
    ],
    targets: [
        .target(
            name: "GlomoPaySDK",
            path: "Sources/GlomoPaySDK"
        ),
        .testTarget(
            name: "GlomoPaySDKTests",
            dependencies: ["GlomoPaySDK"],
            path: "Tests/GlomoPaySDKTests"
        ),
    ]
)
