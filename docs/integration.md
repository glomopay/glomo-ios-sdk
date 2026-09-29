# Analytics and Monitoring Integration

## Runtime configuration

The SDK reads its Mixpanel project token and Sentry DSN from the SDK-owned
`GlomoPayTelemetryConfiguration.plist` resource. Merchant applications do not configure
these values in their `Info.plist`, build settings, or CI. The resource is packaged by Swift
Package Manager.

Release maintainers generate the resource with `scripts/generate-telemetry-config.sh` using
shell environment variables before creating the release tag. Local SDK development can
override bundled values with `GLOMOPAY_MIXPANEL_TOKEN` and `GLOMOPAY_SENTRY_DSN` environment
variables. The SDK never reads these values from the merchant application's `Info.plist`, so
host configuration cannot redirect SDK telemetry.

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
- Mixpanel derives coarse location from the request IP. The SDK privacy manifest declares
  coarse location and marks order-associated analytics data as linked to the user.
- The SDK does not perform App Tracking Transparency tracking. Mixpanel and Sentry are
  analytics/diagnostic processors, not privacy tracking domains, so `NSPrivacyTracking`
  remains disabled and `NSPrivacyTrackingDomains` remains empty.

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

The SDK depends on native Sentry Cocoa through Swift Package Manager with the range
`9.19.1..<10.0.0`. The lower bound is a compatibility floor, not a forced downgrade: SwiftPM can
still resolve a newer 9.x release such as `9.24.0` when the merchant graph allows it. Repository
history does not record a Sentry API reason for preferring `9.19.1` over `9.24.0`; before a
release raises the minimum to `9.24.0` or any later 9.x version, maintainers should record the
compatibility reason and rerun the SDK and sample-app checks against that floor. The SDK creates a
private `SentryClient` and does not invoke `SentrySDK.start`, mutate
the global scope, or reuse a merchant-owned client. Session Replay, automatic sessions,
performance tracing, network tracking, and swizzling are disabled. Only explicitly captured
SDK and analytics-delivery failures are submitted with sanitized, allow-listed context.

SwiftPM may download approximately 740 MB of Sentry XCFramework archives on a cold dependency
resolve. That is a CI cache and dependency-fetch cost, not the application binary size; the final
merchant app links the platform slice it needs.

Merchants already pinned to a different Sentry major may not be able to resolve this package with
their graph. That is the documented escape hatch for a future lightweight envelope client, but it
is not part of this release while native Sentry remains compatible.

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
