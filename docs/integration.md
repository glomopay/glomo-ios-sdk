# Analytics and Monitoring Integration

## Runtime configuration

The SDK reads `GLOMOPAY_MIXPANEL_TOKEN` and `GLOMOPAY_SENTRY_DSN` from the resolved
application `Info.plist`, with process environment variables supported for local tests.
Values must be injected through the release build or CI secret store and must not be
committed to this repository.

If either value is absent, only that integration becomes a no-op. Checkout behavior is
unchanged.

## Mixpanel contract

The implementation sends the shared 38-event native SDK contract directly to
`https://api.mixpanel.com/track?ip=1` using an ephemeral `URLSession`:

- `distinct_id` is the order ID.
- `session_id` is a UUID generated once per checkout invocation.
- `$insert_id` equals `session_id` for event deduplication.
- `sdk_source`, `platform`, and `surface` are `glomo-ios-sdk`, `ios`, and `ios-sdk`.
- Subscription checkouts preserve a null `order_id` and `distinct_id` rather than inventing an identity.
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
product-interaction analytics and SDK diagnostic data, with tracking disabled.

## Isolated Sentry client

The SDK transitively depends on `Sentry/Core` 8.58.4 for CocoaPods and `sentry-cocoa` 8.58.4
for SwiftPM. It creates a private `SentryClient` and does not invoke `SentrySDK.start`, mutate
the global scope, or reuse a merchant-owned client. Session Replay, automatic sessions,
performance tracing, network tracking, and swizzling are disabled. Only explicitly captured
SDK and analytics-delivery failures are submitted with sanitized, allow-listed context.

Merchants already using an incompatible Sentry major version must align their dependency
resolution with Sentry Cocoa 8.x before integrating this SDK.

## Symbols

Because the SDK is source-distributed, its release symbols are part of the merchant app's
dSYM. Complete Sentry symbolication therefore requires the final application dSYM to be
uploaded to the GlomoPay Sentry project from the release build or CI pipeline. No auth token
or symbol-upload credential is embedded in the SDK.
