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
- Direct Mixpanel REST analytics with the shared native event contract, PII filtering, and bank URL sanitization
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

The SDK bundles its Glomo-owned Mixpanel project token and Sentry DSN in an SDK resource.
Merchant applications do not add either value to their `Info.plist`, build settings, or CI.
For local SDK development only, `GLOMOPAY_MIXPANEL_TOKEN` and `GLOMOPAY_SENTRY_DSN`
environment variables can override the bundled values. Blank or missing bundled values select
no-op implementations and never block checkout.

Mixpanel uses the REST `/track` endpoint rather than the native Mixpanel SDK. Analytics
requests are asynchronous, use a 10-second timeout, and are never retried during checkout.
Delivery failures are captured by the isolated SDK-owned Sentry client. The SDK does not
call global Sentry initialization, enable Session Replay, or enable automatic performance,
network, session, or app-wide crash instrumentation.

See [Analytics and monitoring integration](docs/integration.md) for the event identity,
privacy boundaries, dependency compatibility, and release-build requirements.

## Package tests and sample app

Open `Package.swift` in Xcode to build and run the package tests. For manual UI integration testing, open [`SampleApp/GlomoPaySample.xcodeproj`](SampleApp/GlomoPaySample.xcodeproj). The sample app consumes this repository through a local Swift package reference and demonstrates validation, automatic checkout-type detection, native checkout presentation, callbacks, and bridge events.

See the [sample app guide](SampleApp/README.md) for run and optional analytics configuration instructions.

## Release versioning

Keep the same version in `glomo-ios-sdk.podspec`, `CHANGELOG.md`, and the Git release tag. For version `0.0.1`:

Generate the SDK-owned telemetry resource from the release environment before creating the
tag. The script also accepts `MIXPANEL_TOKEN` and `SENTRY_DSN` aliases:

```bash
GLOMOPAY_MIXPANEL_TOKEN="$MIXPANEL_TOKEN" \
GLOMOPAY_SENTRY_DSN="$SENTRY_DSN" \
./scripts/generate-telemetry-config.sh
```

Confirm that `Sources/GlomoPaySDK/Resources/GlomoPayTelemetryConfiguration.plist` contains
the release values. Because SPM and CocoaPods distribute this repository's tagged source,
the generated resource must be included in the release tag. Never place a Sentry auth token
or symbol-upload credential in this file.

```bash
git tag 0.0.1
git push origin 0.0.1
```
