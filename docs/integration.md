# Analytics and Monitoring Integration

## Runtime configuration

The SDK reads its Mixpanel project token and Sentry DSN from the SDK-owned
`GlomoPayTelemetryConfiguration.plist` resource. Merchant applications do not configure
these values in their `Info.plist`, build settings, or CI. The resource is packaged by both
SwiftPM and CocoaPods.

Release maintainers generate the resource with `scripts/generate-telemetry-config.sh` using
shell environment variables before creating the release tag. Local SDK development can
override bundled values with `GLOMOPAY_MIXPANEL_TOKEN` and `GLOMOPAY_SENTRY_DSN` environment
variables. A host `Info.plist` value remains a backward-compatible development override, but
is not part of merchant integration.

If either value is absent, only that integration becomes a no-op. Checkout behavior is
unchanged.

## Mixpanel contract

The implementation sends the shared native SDK event contract directly to
`https://api.mixpanel.com/track?ip=1` using an ephemeral `URLSession`:

- `distinct_id` is the order ID, or the subscription ID for subscription checkouts.
- `session_id` is a UUID generated once per checkout invocation.
- `sdk_source`, `platform`, and `surface` are `glomo-ios-sdk`, `ios`, and `ios-sdk`.
- Subscription checkouts send their subscription ID as `order_id` and `distinct_id`, while
  preserving the same value in `subscription_id`.
- Requests are asynchronous, have a 10-second timeout, and do not retry.

## Privacy boundary

Analytics is allow-by-contract and sanitized before transport. Email addresses, long bare
numeric identifiers, PAN, passport, and voter ID patterns are redacted. Property names
associated with customer, card, bank-account, and KYC data are dropped. Main checkout URLs
drop credentials, query, and fragment data when used as navigation properties. Bank redirect
events are stricter and retain only `https://hostname`; path, port, credentials, query, and
fragment are removed.

The SDK does not collect customer names, email addresses, phone numbers, PAN/card data, bank
account numbers, or KYC document contents. The bundled `PrivacyInfo.xcprivacy` declares
product-interaction analytics, SDK diagnostic data, and device performance data, with tracking
disabled.

At checkout invocation, the SDK collects one diagnostic performance snapshot and attaches it
only to the existing `SDK Initialized` Mixpanel event. The snapshot can include battery level
and state, Low Power Mode, thermal state, physical memory, process memory, jetsam headroom, and
active processor count. Collection is fail-open, does not delay checkout, does not require a
merchant permission or entitlement, and is not used for user tracking. Unknown values are sent
as null. The SDK does not continuously sample device performance.

The same initialization event includes one `NWPathMonitor` reading for Wi-Fi and cellular
interface state. The monitor is cancelled after its first satisfied reading or after a bounded
250 ms timeout. Unsatisfied paths and timeouts preserve both values as null, and no continuous
network monitoring occurs.

## Isolated Sentry client

The SDK transitively depends on `Sentry/Core` 8.58.4 for CocoaPods and `sentry-cocoa` 8.58.4
for SwiftPM. It creates a private `SentryClient` and does not invoke `SentrySDK.start`, mutate
the global scope, or reuse a merchant-owned client. Session Replay, automatic sessions,
performance tracing, network tracking, and swizzling are disabled. Only explicitly captured
SDK and analytics-delivery failures are submitted with sanitized, allow-listed context.

Merchants already using an incompatible Sentry major version must align their dependency
resolution with Sentry Cocoa 8.x before integrating this SDK.

### Manual Sentry delivery verification

Release maintainers can send one sanitized synthetic SDK error through the isolated client:

```bash
GLOMOPAY_RUN_SENTRY_DELIVERY_TEST=1 \
swift test --filter IsolatedSentryDeliveryTests/testManualSDKErrorDelivery
```

The test is skipped during normal test runs and does not initialize global Sentry. Confirm the
`manual_sentry_delivery_test` event in the GlomoPay iOS SDK Sentry project after it completes.

## Symbols

Because the SDK is source-distributed, its release symbols are part of the merchant app's
dSYM. Complete Sentry symbolication therefore requires the final application dSYM to be
uploaded to the GlomoPay Sentry project from the release build or CI pipeline. No auth token
or symbol-upload credential is embedded in the SDK.
