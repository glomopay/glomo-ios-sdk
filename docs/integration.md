# Analytics and Monitoring Integration

## Runtime configuration

The SDK reads its Mixpanel project token and Sentry DSN from the SDK-owned
`GlomoPayTelemetryConfiguration.plist` resource. Merchant applications do not configure
these values in their `Info.plist`, build settings, or CI. The resource is packaged by both
SwiftPM and CocoaPods.

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

The SDK has no Sentry SDK dependency. It reports explicitly captured SDK and analytics-delivery
failures by POSTing Sentry envelopes over `URLSession` to the endpoint derived from the bundled
DSN. It installs no crash or exception handlers, swizzles nothing, keeps no global scope, writes
nothing to disk, and never touches a merchant-owned Sentry client. Only sanitized, allow-listed
context is sent; events carry no user fields (no id, email, username or name) and no request.

Sentry events record the device's public IP address and IP-derived country and city, plus OS,
device and app context. The SDK sets `sdk.settings.infer_ip: auto`, and Sentry takes the address
from the connection, for correlation with backend and edge logs. The privacy manifest declares
coarse location for analytics and app functionality.

Events identify as `glomo-ios-sdk/<SDK version>`, with `release` `glomo-ios-sdk@<SDK version>`
and `environment` `glomo-ios-sdk`, so Sentry releases track the SDK version, not the host app's.
No `dist` and no host bundle id are sent. The `contexts` block carries: OS name, version
and build; the device's hardware model identifier, family and a simulator flag; and the host
app's version and build. No device name, vendor or advertising identifier, locale, timezone,
battery, memory or view names are sent.

Requests time out after 10 seconds, are never retried, and anything caught by a Sentry rate
limit is dropped rather than queued.

Merchants can use any Sentry version, or none, alongside this SDK.

### Manual Sentry delivery verification

Release maintainers can send one clearly marked synthetic event (operation `delivery_test`, tag
`delivery_test=true`, message "GlomoPay SDK delivery test - safe to resolve"). It asserts that
Sentry answers 200 and prints the event id and the send time in IST, never the DSN:

```bash
GLOMOPAY_RUN_SENTRY_DELIVERY_TEST=1 \
swift test --filter IsolatedSentryDeliveryTests/testManualSDKErrorDelivery
```

On a simulator, so the event carries iOS OS and device context, pass the variables with the
`TEST_RUNNER_` prefix, which `xcodebuild` forwards to the test process:

```bash
TEST_RUNNER_GLOMOPAY_RUN_SENTRY_DELIVERY_TEST=1 \
TEST_RUNNER_GLOMOPAY_SENTRY_DSN="$(cat path/to/dsn.txt)" \
xcodebuild test -scheme glomo-ios-sdk -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:GlomoPaySDKTests/IsolatedSentryDeliveryTests/testManualSDKErrorDelivery
```

The test is skipped during normal test runs. It sends to the bundled DSN unless
`GLOMOPAY_SENTRY_DSN` overrides it, and reports which source it used.

## Symbols

Error events carry no stack trace, so no dSYM upload is needed for SDK error reporting. From a
merchant's release build the frames would be unsymbolicated addresses in the merchant's binary,
and GlomoPay never receives the merchant's dSYMs. The event message names the failed operation
and the error type instead. No auth token or symbol-upload credential is embedded in the SDK.
