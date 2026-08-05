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

The SDK accepts the merchant's **publishable key**. It is publishable by design,
is present in every distributed build, and grants no read access to any data.
Reports about its visibility will be closed as intended behaviour.

A Segment analytics write key was previously embedded in this SDK. It has been
removed and is being rotated. It remains visible in git history and in the `0.0.1`
tag — that is expected, and rotation is what addresses it; reports about the
historical value are not vulnerabilities.

The SDK sends no analytics or telemetry to any third party. `GlomoPayLogger`
writes to the local console in developer mode only.
