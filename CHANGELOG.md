# Changelog

All notable changes to the GlomoPay iOS SDK are documented here.

## Unreleased

### Breaking

- `GlomoPayListener.onUserJourneyCompleted(_:)` is a new **required** callback with no
  protocol-extension default, so every integration must add it. Required on purpose, and
  deliberately breaking the pattern the extension's other default sets: the SDK cannot tell which
  merchants have bank transfers enabled - the order decides that, server side - so a default body
  would let a host upgrade, keep compiling, and silently stop hearing about a journey it used to be
  told about.
- `payment.bank_transfer_submitted` no longer reaches `onPaymentSuccess`. Hosts that fulfil orders
  from `onPaymentSuccess` were being told a payment had completed when no money had moved.
- `GlomoPayListener.onEvent` is removed, `GlomoPayConfig.devMode` is replaced by a build-time flag,
  `autoCloseOnConnectionError` moved onto `GlomoPayConfig`, `startCheckout` now returns a handle,
  and `CheckoutStatus`, `TerminationSource.backButton`, `GlomoPayResult` and
  `GlomoPaySDK.checkoutURL` are gone from the public surface.

### Flutter v2 parity

- `onPaymentFailure` is delivered on the checkout's failure event instead of requiring a signature
  that a failure payload has never carried. The callback previously could not fire for a
  backend-confirmed decline in any build, and the host received an `onSdkError` describing the SDK's
  own guard instead. A payload with no `orderId` is still delivered and captured as
  `thin_payment_failure_payload`.
- Added `GlomoPayUserJourneyPayload` and `GlomoPayUserJourneyType`, and routed
  `payment.bank_transfer_submitted` to `onUserJourneyCompleted`. Journey fields are read coercively
  in both camelCase and snake_case, extending the style `GlomoPayPayload(json:)` already used - a
  cast would throw inside the delivery path after the one-result latch is spent, losing the transfer
  entirely. A payload with no `orderId` is rejected but captured as `thin_bank_transfer_payload`
  rather than surfacing as a generic SDK error.
- The journey type ships with one member. Pay-via-bank is sunset on iOS: the
  `glomoCheckoutJourneyTerminate` case and the `Pay Via Bank Completed` event are removed, because
  an event that fires with no callback, payload type or enum member behind it made dashboards show a
  live-looking signal for a journey no merchant is told about. If the page still emits it, it now
  falls through as `Unsupported Functionality Used`, which is the correct outcome - worth confirming
  with the web team rather than assuming.
- Removed the duplicate `dependencies.failed_to_load` handler that tracked the same failure twice
  for one message, and with the `onEvent` removal the SDK-invented `checkout.dependencies_failed`
  alias is gone too. The page's failure keeps the page's own name. No dialog is drawn over the
  page's own error screen and no console output is interpreted; both were already correct.
- The page's `accept` types are reported but no longer retained. With no document picker to filter,
  the stored value had no reader - and it was read a run loop turn before it was written, so the
  first upload of a session filtered on nothing. That race is gone with the property rather than
  fixed.

### Blocking parity fixes

- Order-fetch failure now terminates the checkout and reports the cause instead of resolving to
  "standard" and opening the standard checkout, which routed LRS orders to the wrong host. The
  test that asserted the fallback was removed.
- `GlomoPayAPIError` cases now travel to the caller instead of being flattened into `.network`:
  a timeout and a transport failure report through `onConnectionError`, a non-2xx status and an
  unparseable response through `onSdkError`. No case carries the response body any more - it
  reached analytics and Sentry as `localizedDescription`, unredacted.
- Added the LRS education carousel: a hosted third WebView above the bank page with Flutter's
  5% bar / 15% strip proportions, a fixed 48pt bar when hidden, the page's
  `{ event, hasContent }` contract, and a 3-second DOM-poll fallback. The router's availability
  read was matching a `value` field the page never sends.
- Back in the bank overlay now always closes the overlay instead of walking the bank page's
  history, which made the exit unreachable once a redirect chain left history behind. Edge-swipe
  history gestures are disabled on both WebViews.
- Added the `window.opener` stub to the flow injection, so bank pages that report results through
  `opener.postMessage` are heard instead of completing at the bank silently.
- The bank flow WebView now allows only `http`, `https`, `about`, `blob` and `data` navigations
  and reports blocked attempts as `Non HTTP Navigation Attempted`. The main WebView is
  deliberately unfiltered: it only loads GlomoPay's own checkout document.
- Added `Validator.isValidUrl` and gated the bridge's `window.open` on it. `URL(string:)` is a
  parse, not a check, so `javascript:`, `data:` and `file:` URLs from the page became navigations.
  A rejected URL is captured rather than dropped silently.
- `NSURLErrorCancelled` is no longer reported as a connection error. WebKit delivers it routinely
  - superseded provisional navigations, client-side redirects, `stopLoading()` - and with
  auto-close on it terminated live checkouts for a non-event. `closeFlow()` now clears the
  navigation delegate before `stopLoading()`.
- `shouldAutoClose` is decided from the mapped error type instead of the sign of the error code.
  Every `NSURLErrorDomain` code is negative and every `WKErrorDomain` code is positive, so the
  old rule closed on all unmapped iOS errors and exempted genuine WebKit failures.

### Merchant readiness

- Added the checkout-open funnel with the five shared wire names, a `Checkout Open Timeout` event
  carrying `last_step` and a required `reason`, a companion `Checkout Opened After Timeout`, and a
  15-second advisory render timeout. There was previously no timeout of any kind behind
  "Loading checkout...", so a page that never rendered left the user on a spinner with no error,
  no retry and no callback. The outer watchdog is derived from the order-API timeout plus the
  render budget plus a margin, never hard-coded.
- Added `bridge.ready` to the injection and the router, which is both the final funnel step and
  what stands the timeouts down.
- `autoCloseOnConnectionError` moved to `GlomoPayConfig`. It was a property on the checkout view
  controller, which `startCheckout` constructs internally and never exposes, so no merchant
  integrating from the README could reach it.
- Replaced merchant-settable `devMode` with the compile-time `GLOMO_INTERNAL_BUILD` flag resolved
  by `Package.swift` for SDK-controlled internal builds. The podspec deliberately leaves its
  equivalent compile condition commented out so merchant releases fail closed. `devMode: true`
  with a live key used to skip the jailbreak and debugger block entirely, and the sample app
  shipped it enabled by default.
  `GlomoPayLogger.devMode` was a public `static var` any merchant could set process-wide while the
  controller also assigned it from the config; it is now internal and compile-time only. Analytics
  still reports `dev_mode`, and telemetry is still gated on token/DSN presence alone.
- The checkout's WebViews now share one `nonPersistent()` website data store instead of the
  app-wide `.default()` one, which was never cleared: checkout cookies, localStorage and cache
  persisted into the merchant application's own WebViews and into the next checkout. Nothing clears
  app-wide website data, which would destroy a 3DS session mid-redirect.
- `startCheckout` returns a `GlomoPayCheckoutHandle` with `close()`, so a host can dismiss an
  in-flight checkout. `TerminationSource.programmatic` is no longer dead.
- Every host callback now goes through one delivery point, on the main queue, that reports a
  released listener as `Listener Unavailable` in analytics and Sentry. The listener is weak, which
  previously meant a host passing an object it did not otherwise retain got no callbacks, no error
  and no signal at all. The retention contract is documented at the `startCheckout` call site and
  in the README.
- Moved every user-facing string into a `GlomoPayLocalizable` table a host can override, and gave
  the bank-flow error path a real surface with retry and cancel. It previously reached into the
  loading view's subviews by type to find a label and wrote an untranslated `NSError` description
  into it, with no controls. The main error panel gained a Cancel button.
- Added an iOS-simulator `xcodebuild test` job. `swift test` builds for macOS, where
  `canImport(UIKit)` is false, so the checkout controller - every WebView behaviour in the SDK - was
  compiled out of the test binary and never executed. Added 20 tests that run it: bridge message in
  and host callback out (success, signature-less failure, bank-transfer journey), the flow overlay
  open / back / page-close cycle, a rejected `window.open` URL never opening an overlay, the
  cancelled-navigation and real-load-failure paths, an unmapped WebKit failure showing retry instead
  of closing, and order-fetch timeout and status failures terminating without navigating. The
  controller's event router is internal rather than private so those tests exercise the real path
  instead of a parallel fake.

### Removed

- `CheckoutStatus`, which was declared, referenced nowhere, and carried the member set that
  reported a submitted bank transfer as `paymentSuccessful`.
- `TerminationSource.backButton`, which has no meaning on iOS: the escapes are the navigation bar's
  Close button and interactive sheet dismissal, both reported as `userDismiss`.
- `GlomoPayListener.onEvent` and its protocol-extension default, along with roughly 30 emit sites.
  It is not part of the integration contract. Everything with diagnostic value moved to analytics,
  which is sanitised and does not depend on a host implementing anything; the only signals that had
  no analytics counterpart were `navigation.committed` and `flow.page_committed`, which the open
  funnel now covers. Page events the SDK does not route are tracked as
  `Unsupported Functionality Used` rather than forwarded.
- `GlomoPaySDK.checkoutURL(for:orderType:)` is now internal - it had no call sites outside tests.
- The `runOpenPanelWith` document picker. WebKit's own sheet offers Camera, Photo Library and
  Files on every supported OS; the SDK's picker removed those options on iOS 18.4+. See the
  file-upload section in the README for the recorded decision and its cost.
- `FileAcceptTypeResolver` and the `File Picker Error` event, which existed only for that picker.
  The abandoned-completion-handler risk goes with them: WebKit's contract is that the open-panel
  handler is called exactly once, and the SDK stored it and relied on document-picker delegate
  callbacks to discharge it - nothing did if the checkout was dismissed while the picker was up.
  With no delegate implementation there is no handler to hold.

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
- Battery monitoring now starts before the initialization snapshot, preserves host-app state,
  and reports unavailable process-memory readings as null.
- The initialization snapshot now includes a bounded one-shot network-path reading, with null
  Wi-Fi and cellular values retained for unsatisfied paths or timeouts.
- Subscription analytics now use the subscription ID for Mixpanel `order_id` and `distinct_id`.
- Analytics delivery payloads and transport/error-reporting boundaries are now concurrency-safe
  with `Sendable` types.
