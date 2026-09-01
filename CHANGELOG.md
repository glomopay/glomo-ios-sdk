# Changelog

All notable changes to the GlomoPay iOS SDK are documented here.

## [0.0.1] - 2026-08-01

### Added

- Initial native Swift SDK package for iOS 15 and later.
- CocoaPods specification with `glomo-ios-sdk` version `0.0.1`.
- Swift Package Manager support through `Package.swift`.
- Typed checkout configuration, payload, result, error, and listener contracts.
- Native modal `WKWebView` checkout flow with loading, retry, navigation, and cancellation handling.
- Standard and LRS checkout support with automatic order-based checkout detection.
- JavaScript bridge and Flutter-compatible payment event routing.
- Device compliance checks, local logging, and XCTest coverage.
- Direct Mixpanel REST analytics implementing the shared native SDK event contract.
- Isolated Sentry reporting for explicitly captured SDK and analytics failures.
- Analytics PII filtering, bank redirect URL origin sanitization, and privacy manifest.
- One-time iOS device performance snapshot on `SDK Initialized` for checkout reliability diagnostics.

### Changed

- Renamed the CocoaPods pod and Swift Package product to `glomo-ios-sdk` while
  preserving the `GlomoPaySDK` Swift module and public API.
- Updated distribution metadata and documentation for the new repository name.
- Analytics failures are fire-and-forget and cannot interrupt the checkout journey.
- Mixpanel and Sentry client configuration is bundled by the SDK, so merchants do not add
  telemetry values to their application `Info.plist`.
