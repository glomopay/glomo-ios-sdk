# GlomoPay iOS Swift SDK

Native Swift implementation of the GlomoPay checkout SDK. The public contract is intentionally aligned with the Flutter and Kotlin SDKs.

Current release: `0.0.1`

## Installation with CocoaPods

Add the GlomoPay pod to the application `Podfile`:

```ruby
platform :ios, '15.0'

target 'YourApp' do
  pod 'GlomoPaySDK', '0.0.1'
end
```

Then install the dependency:

```bash
pod install
```

Open the generated `.xcworkspace` file and import the SDK:

```swift
import GlomoPaySDK
```

## Installation with Swift Package Manager

Add the Git repository URL in Xcode and select the `0.0.1` release tag:

```text
https://github.com/mayankmatkar/glomopay-ios-sdk.git
```

The package product is named `GlomoPaySDK`.

## Current foundation

- Swift Package Manager library targeting iOS 15+
- Flutter-compatible configuration, identifiers, modes, URL generation, payloads, results, and validation
- `URLSession` order API client with Bearer authentication and JSON parsing
- Injectable HTTP client for deterministic API tests without live network calls
- Native `WKWebView` checkout controller with modal presentation, loading state, retry, and navigation/error handling
- Dedicated `Bridge` layer for WKScriptMessageHandler, injection scripts, and Flutter/Kotlin-compatible event routing
- Isolated `Security` layer for jailbreak/debugger checks with Flutter/Kotlin strict-mode policy
- Non-blocking analytics and logging layer with injectable transport and release-safe diagnostics
- Shared JavaScript injection contract for the upcoming `WKWebView` bridge
- XCTest coverage for validation, URL generation, API errors, payloads, bridge events, security policy, analytics, and iOS WebView safeguards

## Checkout flow

1. `GlomoPaySDK.startCheckout` validates the configuration.
2. A native page-sheet modal presents `GlomoPayCheckoutViewController`.
3. The checkout document loads in `WKWebView` with browser-like iOS headers.
4. HTTP/WebView errors expose retry and cancellation behavior; iOS `-1017` receives one controlled document retry.
5. JavaScript events are routed through `WKScriptMessageHandler` and normalized by the bridge event router.
6. Standard and LRS checkout URLs use the same Flutter/Kotlin query contract.

## Package tests and UI testing

Open `Package.swift` in Xcode to build and run the package tests. For manual UI integration testing, use the standalone [iOS SDK test app](../glomopay-ios-sdk-test-app/README.md), which consumes this package through a local package dependency.

## Release versioning

Keep the same version in `GlomoPaySDK.podspec`, `CHANGELOG.md`, and the Git release tag. For version `0.0.1`:

```bash
git tag 0.0.1
git push origin 0.0.1
```
