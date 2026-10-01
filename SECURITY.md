# Security policy

## Reporting a vulnerability

Do not open a public issue for security reports.

Email **security@glomopay.com** with a description, affected SDK versions, and
reproduction steps. We aim to acknowledge within two business days.

## Scope

This SDK is a thin wrapper that presents GlomoPay's hosted checkout inside a
`WKWebView`. It does not capture, store, or transmit card numbers, CVVs, or KYC
document contents. Card data is handled entirely by the hosted checkout page.

Reports that depend on modifying the host application, jailbreaking the device, or
attaching a debugger are generally out of scope — the SDK's device compliance
checks are a deterrent, not a security boundary.

## What is not a vulnerability

The SDK accepts the merchant's **publishable key**, which is intended for
client-side use and does not grant read access to merchant or payment data.
Reports solely about the visibility of that publishable key will be closed as
intended behaviour.

The SDK also bundles a Mixpanel project token and Sentry DSN. These are
publishable client-side identifiers that provide no read access to either
service. Sentry auth tokens and symbol-upload credentials are never bundled.
