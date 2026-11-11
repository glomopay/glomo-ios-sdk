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

- Events follow Glomo's RFC-4 catalogue, shared with the other native SDKs and the web SDK:
  `sdk_loaded`, `sdk_page_viewed`, `sdk_api_backend`, `sdk_action_submitted`,
  `sdk_action_failed`, `sdk_cta_clicked`, `sdk_control_changed`, `sdk_checkout_failed` and
  `sdk_checkout_closed`. Keys are snake_case and values come from fixed lists.
- `journey_id` is a lowercase UUID generated once per checkout invocation. The same value is
  sent as `$device_id` and appended to the checkout URL as `journeyId`.
- `distinct_id` is `$device:<journey_id>`: the Mixpanel identity is anonymous and new for each
  checkout open, and the SDK never calls identify. Events still carry order-linked identifiers
  (`resource_id`, `public_key`), so the privacy manifest declares this analytics data as linked
  to the user.
- `integration` is `ios_sdk` and `platform` is `ios` on every event.
- `resource_id` is the order ID, or the subscription ID for subscription checkouts. `journey` is
  `standard`, `lrs` or `subscription` once the order type is known. `key_mode` is `live` for a
  `live_` key and `test` for a `test_` or `mock_` key, and is omitted otherwise.
- `sdk_loaded`, `sdk_page_viewed` with `page_name: checkout` and `sdk_checkout_closed` are sent
  once per checkout invocation, and `sdk_checkout_failed` once per `error_code`.
- `$insert_id` is a fresh lowercase UUID on every event, so Mixpanel never deduplicates two
  distinct events.
- Requests are asynchronous, have a 10-second timeout, and do not retry.
- Mixpanel derives coarse location from the request IP. The SDK privacy manifest declares
  coarse location and marks order-associated analytics data as linked to the user.
- The SDK does not perform App Tracking Transparency tracking. Mixpanel and Sentry are
  analytics/diagnostic processors, not privacy tracking domains, so `NSPrivacyTracking`
  remains disabled and `NSPrivacyTrackingDomains` remains empty.

## Privacy boundary

Analytics is allow-by-contract and masked before transport. A property whose snake_case key has
a customer-data token (`email`, `phone`, `mobile`, `pan`, `aadhaar`, `name`, `account`, `card`,
`address`, `dob`, `token`, `otp`, `passport`, `voter`) is masked rather than dropped; fixed-list
taxonomy keys such as `page_name` are exempt. String values under any key are masked by pattern:
email as `j•••@domain`, a Luhn-valid card number as `XXXX-XXXX-XXXX-1234`, a tax PAN as
`XXXXXX234F`, a 10-12 digit number as `••••1234`, and passport or voter IDs as `•••`.
Identifiers (`resource_id`, `journey_id` and the like), values that are wholly a UUID, and
device/host-app metadata such as the app version and build pass unchanged. Every string,
identifiers included, is capped at 1,000 characters, and arrays and objects are dropped. URLs
are sent only as an origin (`url_origin`); bank redirect origins keep only `https://hostname`.

The SDK does not collect customer names, email addresses, phone numbers, PAN/card data, bank
account numbers, or KYC document contents. The bundled `PrivacyInfo.xcprivacy` declares
product-interaction analytics, SDK diagnostic data and coarse location, with tracking disabled.

The SDK sends no device performance or device-posture data to analytics.

At checkout invocation, the SDK takes one `NWPathMonitor` reading for Wi-Fi and cellular
interface state and attaches it to later events as `$wifi_enabled` and `$cellular_enabled`. The
monitor is cancelled after its first satisfied reading or after a bounded 250 ms timeout.
Unsatisfied paths and timeouts leave both values unset, and no continuous network monitoring
occurs.

## Isolated Sentry client

The SDK has no Sentry SDK dependency. It reports explicitly captured SDK and analytics-delivery
failures by POSTing Sentry envelopes over `URLSession` to the endpoint derived from the bundled
DSN. It installs no crash or exception handlers, swizzles nothing, keeps no global scope, writes
nothing to disk, and never touches a merchant-owned Sentry client. Only sanitized, allow-listed
context is sent; events carry no user fields (no id, email, username or name) and no request.

The SDK sends no IP address and sets `sdk.settings.infer_ip: never`. Sentry derives approximate
location (country, region, city) at ingest and does not store the device IP. The setting is
required: left unset, Sentry treats the Cocoa platform as `auto` and stores the connection IP.
The privacy manifest declares coarse location for analytics and app functionality.

Each event is tagged `order_id` with the checkout's order id (or subscription id), the same value
analytics sends as `resource_id`, so it can be joined to backend logs. When events are discarded
(rate limited, over the in-flight bound, a 5xx or a transport failure), the next event that goes
out carries the count as `extra.dropped_since_last_send`, so a quiet project can be told apart
from one whose reports are being thrown away. The HTTP body is gzip-compressed
(`Content-Encoding: gzip`).

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
