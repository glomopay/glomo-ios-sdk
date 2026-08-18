# Glomo iOS SDK

Native Swift implementation of the GlomoPay checkout SDK. The public contract is intentionally aligned with the Flutter and Kotlin SDKs.

Current release: `0.0.1`

## Installation with CocoaPods

Add the GlomoPay pod to the application `Podfile`:

```ruby
platform :ios, '15.0'

target 'YourApp' do
  pod 'glomo-ios-sdk', '0.0.1'
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
https://github.com/glomopay/glomo-ios-sdk.git
```

The package product is named `glomo-ios-sdk`. The Swift module remains
`GlomoPaySDK`, so merchant applications continue to use `import GlomoPaySDK`.

## Current foundation

- Swift Package Manager library targeting iOS 15+
- Flutter-compatible configuration, identifiers, modes, URL generation, payloads, results, and validation
- `URLSession` order API client with Bearer authentication and JSON parsing
- Injectable HTTP client for deterministic API tests without live network calls
- Native `WKWebView` checkout controller with modal presentation, loading state, retry, and navigation/error handling
- Dedicated `Bridge` layer for WKScriptMessageHandler, injection scripts, and Flutter/Kotlin-compatible event routing
- Isolated `Security` layer for jailbreak/debugger checks with Flutter/Kotlin strict-mode policy
- Local, developer-mode logging through `GlomoPayLogger`
- Direct Mixpanel REST analytics with the shared native 38-event contract, PII filtering, and bank URL sanitization
- Isolated Sentry error reporting for SDK/analytics failures without global `SentrySDK.start` initialization
- Bundled privacy manifest covering analytics and SDK diagnostics
- Shared JavaScript injection contract for the upcoming `WKWebView` bridge
- XCTest coverage for validation, URL generation, API errors, payloads, bridge events, security policy, and iOS WebView safeguards

## Checkout flow

1. `GlomoPaySDK.startCheckout` validates the configuration.
2. A native page-sheet modal presents `GlomoPayCheckoutViewController`.
3. The checkout document loads in `WKWebView` with browser-like iOS headers.
4. HTTP/WebView errors expose retry and cancellation behavior; iOS `-1017` receives one controlled document retry.
5. JavaScript events are routed through `WKScriptMessageHandler` and normalized by the bridge event router.
6. Standard and LRS checkout URLs use the same Flutter/Kotlin query contract.

## Analytics and diagnostics configuration

The SDK reads its Glomo-owned integration values from the host application's resolved
`Info.plist`. Keep the actual values outside source control and expose them through build
settings:

```xml
<key>GLOMOPAY_MIXPANEL_TOKEN</key>
<string>$(MIXPANEL_TOKEN)</string>
<key>GLOMOPAY_SENTRY_DSN</key>
<string>$(SENTRY_DSN)</string>
```

For local command-line testing, the same names may be supplied as environment variables.
Blank or missing values select no-op implementations and never block checkout.

Mixpanel uses the REST `/track` endpoint rather than the native Mixpanel SDK. Analytics
requests are asynchronous, use a 10-second timeout, and are never retried during checkout.
Delivery failures are captured by the isolated SDK-owned Sentry client. The SDK does not
call global Sentry initialization, enable Session Replay, or enable automatic performance,
network, session, or app-wide crash instrumentation.

See [Analytics and monitoring integration](docs/integration.md) for the event identity,
privacy boundaries, dependency compatibility, and release-build requirements.

## Package tests and UI testing

Open `Package.swift` in Xcode to build and run the package tests. For manual UI integration testing, use the standalone [iOS SDK test app](../glomopay-ios-sdk-test-app/README.md), which consumes this package through a local package dependency.

## Release versioning

Keep the same version in `glomo-ios-sdk.podspec`, `CHANGELOG.md`, and the Git release tag. For version `0.0.1`:

```bash
git tag 0.0.1
git push origin 0.0.1
```
