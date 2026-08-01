# GlomoPay iOS Swift SDK

Native Swift implementation of the GlomoPay checkout SDK. The public contract is intentionally aligned with the Flutter and Kotlin SDKs.

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
- XCTest coverage for validation, URL generation, API errors, payloads, bridge events, security policy, analytics, iOS WebView safeguards, and sample-app integration flows

## Checkout flow

1. `GlomoPaySDK.startCheckout` validates the configuration.
2. A native page-sheet modal presents `GlomoPayCheckoutViewController`.
3. The checkout document loads in `WKWebView` with browser-like iOS headers.
4. HTTP/WebView errors expose retry and cancellation behavior; iOS `-1017` receives one controlled document retry.
5. JavaScript events are routed through `WKScriptMessageHandler` and normalized by the bridge event router.
6. Standard and LRS checkout URLs use the same Flutter/Kotlin query contract.

## Open in Xcode

Open `Package.swift` in Xcode to build and run the package tests. The iOS example application will be added next and will consume this package through a local package dependency.
