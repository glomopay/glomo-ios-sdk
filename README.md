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

## SDK capabilities

- Swift Package Manager library targeting iOS 15+
- Flutter-compatible configuration, identifiers, modes, URL generation, payloads, results, and validation
- `URLSession` order API client with Bearer authentication and JSON parsing
- Injectable HTTP client for deterministic API tests without live network calls
- Native `WKWebView` checkout controller with modal presentation, loading state, retry, and navigation/error handling
- Dedicated `Bridge` layer for WKScriptMessageHandler, injection scripts, and Flutter/Kotlin-compatible event routing
- Isolated `Security` layer for jailbreak/debugger checks with Flutter/Kotlin strict-mode policy
- Internal-only developer logging, gated on an SDK build-time flag with no merchant-facing switch
- Direct Mixpanel REST analytics with the shared native event contract, PII filtering, and bank URL sanitization
- Isolated Sentry error reporting for SDK/analytics failures without global `SentrySDK.start` initialization
- Bundled privacy manifest covering analytics and SDK diagnostics
- Document-start JavaScript bridge for checkout, bank overlays, carousel availability, and payment events
- XCTest coverage for validation, URL generation, API errors, payloads, bridge events, security policy, and iOS WebView safeguards

## Checkout flow

1. `GlomoPaySDK.startCheckout` validates the configuration.
2. A native page-sheet modal presents `GlomoPayCheckoutViewController`.
3. The checkout document loads in `WKWebView` with browser-like iOS headers.
4. HTTP/WebView errors expose retry and cancellation behavior; iOS `-1017` receives one controlled document retry.
5. JavaScript events are routed through `WKScriptMessageHandler` and normalized by the bridge event router.
6. Standard and LRS checkout URLs use the same Flutter/Kotlin query contract.

### Order type detection

The order type is resolved from a successful order fetch, or the checkout does not open. A
failed fetch is reported by cause - a timeout or transport failure through `onConnectionError`,
a non-2xx status or an unparseable response through `onSdkError` - and the session ends. The SDK
does not fall back to standard checkout, because guessing would route LRS traffic to the wrong
checkout host. Any fallback is a product decision, not a catch block.

### Bank flow overlay

Back in the overlay always closes the overlay and returns the user to checkout. It does not walk
the bank page's own history: redirect chains leave history that never drains, so history-walking
makes the exit unreachable. Edge-swipe history gestures are disabled on both WebViews for the
same reason.

The overlay allows `http`, `https`, `about`, `blob` and `data` navigations and blocks everything
else. WKWebView never hands an unknown scheme to the system, so a `upi://` or `intent://`
navigation would otherwise fail silently and leave the user on a bank page that appears to have
done nothing. Blocked attempts are reported as `Non HTTP Navigation Attempted`. Whether iOS
should open such URLs through `UIApplication` is a separate product decision.

### LRS education carousel

For LRS orders the overlay shows a 5% back bar and a 15% education strip above the bank page,
loaded from the hosted carousel. The strip appears only when the page reports
`{ event: 'lrs.has_education_steps', hasContent: true }`; a 3-second DOM poll covers pages that
render content without announcing it. When there is nothing to show, the bar is a fixed 48pt and
the bank page takes the rest.

### Payment outcomes and journeys

`onPaymentFailure` is delivered on the checkout's failure event itself. Do not expect a `signature`
on it: that field exists so a host can verify a *success*, and a failure payload has never carried
one. The page's response travels verbatim in `rawResponse`.

`onUserJourneyCompleted` is **required** - it has no default implementation - and reports a
non-payment journey. Today that is submitted bank-transfer details, carrying
`GlomoPayUserJourneyPayload`: a journey type, order ID, sender account number, transaction
reference, status and raw response. It is deliberately not a `GlomoPayPayload`, because there is no
`paymentId` and no `signature` here and no money has moved. Reconcile it server-side against the
order; never fulfil an order from it. This used to arrive through `onPaymentSuccess`, which told
hosts a payment had completed when it had not.

The journey type carries one member. Pay-via-bank (lean / open finance) is sunset and unsupported
on iOS - matching Flutter and diverging from the RN SDK on purpose - so there is no member for it
and no event behind it.

### Listener retention and callback rules

The SDK holds the listener **weakly**: it does not keep a merchant object alive. Retain it for at
least as long as the checkout. A coordinator or handler that nothing else references will be
released mid-checkout, and the payment result cannot then be delivered - the SDK reports that as
`Listener Unavailable` in analytics and captures it to Sentry, but the result is still gone.

Callbacks arrive on the main queue. They must not throw or trap: Swift has no catchable exception
mechanism, so a force-unwrap of nil or an out-of-range index inside a callback traps the host
process and the SDK cannot contain it.

`startCheckout` returns a `GlomoPayCheckoutHandle`. Retain it to dismiss that session with
`handle.close()`; the listener then receives `onPaymentTerminate(.programmatic)` once. Calls after
the checkout has finished do nothing.

There is no `onEvent`. The diagnostic channel it provided is not part of the integration
contract; everything with diagnostic value goes to Mixpanel and Sentry instead.

### Load timeouts and the open funnel

The checkout records a monotonic open funnel - `webview_created`, `url_resolved`,
`navigation_started`, `navigation_finished`, `bridge_ready` - so a checkout that never opened
reports the step it reached. Two budgets sit behind the spinner:

- a 15-second render timeout, which is **advisory**: it reports `onConnectionError` with
  `shouldAutoClose` false and shows a retry surface, because the page may be seconds away;
- an outer watchdog, derived from the order-API timeout plus the render budget plus a margin
  rather than hard-coded, which reports `Checkout Open Timeout` with `last_step` and `reason`.

If the page arrives after a timeout was reported, `Checkout Opened After Timeout` is emitted. The
difference between the two counts is not a failure rate.

`autoCloseOnConnectionError` is set on `GlomoPayConfig`. It defaults to true and applies only to
failures marked as closing: an advisory timeout, a cancelled navigation and an unmapped WebKit
failure all show the retry surface instead.

### Session isolation

The checkout's WebViews share one `WKWebsiteDataStore.nonPersistent()` store - shared because the
3DS redirect chain depends on it, non-persistent so checkout cookies, localStorage and cache never
reach the merchant application's own `WKWebView` instances and a second checkout never starts
against what the first one left behind. The SDK never clears app-wide website data: doing so would
destroy a 3DS session mid-redirect.

### Developer flag

There is no merchant-settable `devMode`. For an SDK-controlled SwiftPM build,
`GLOMO_INTERNAL_BUILD=true` at package resolution defines the compile condition. The podspec keeps
its equivalent `pod_target_xcconfig` example commented out deliberately, so a pod published to
merchants always fails closed. The flag relaxes the jailbreak/debugger block, enables verbose
logging, and rides on every analytics event as `dev_mode` so an internal build is detectable. It
does not gate analytics or error reporting, which are decided by Mixpanel token and Sentry DSN
presence alone.

### User-facing strings

All user-facing text is looked up from a `GlomoPayLocalizable` table. A host can override any key
by declaring it in its own `GlomoPayLocalizable.strings`, because the main bundle is searched
before the SDK's.

### File upload

The SDK deliberately does not implement `WKUIDelegate.runOpenPanelWith`. That method is
iOS 18.4+, and WebKit's contract is that without it "the web view will match the file upload
behavior of Safari" - so WebKit's own sheet, with Camera, Photo Library and Files, is what every
supported OS version gets. Implementing it produced a document picker on 18.4+ that removed
capture options the platform provided for free, on KYC fields where photographing a document is
the common case.

The cost of this position is recorded so it is not rediscovered as a bug: there is no picker
telemetry (the page's own file-input click still reports `File Upload Requested` with its accept
types) and no control over accept-type behaviour, which matches the direction anyway - `accept`
selects which picker opens and never restricts what may be chosen, because the bank re-validates
every upload. Revisiting this means the full picker: an action sheet with camera / photo library
/ files, `PHPickerViewController`, the camera permission and refusal callback, and the capture
caps that keep uploads under the bank's limit.

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
