# Contributing to the GlomoPay iOS SDK

Read this before your first commit. GlomoPay is an RBI-regulated payments company
and this SDK ships inside merchant apps that handle real money, so a few of the
rules below are absolute rather than stylistic. Those are marked **HARD RULE**.

---

## 1. Hard rules

### HARD RULE — no card handling, ever

Do not add card number, CVV, or expiry input; do not tokenize; do not implement
native 3DS or SCA. The hosted checkout page does all of this server-side, and that
boundary is the only reason this SDK — and every app embedding it — stays out of
PCI-DSS scope.

Displaying a bank's 3DS redirect inside the WebView is fine; that is just showing
their page. Implementing SCA natively is not. A native card form would feel like a
UX improvement and would be a compliance incident. If a requirement seems to need
one, stop and raise it.

### HARD RULE — third-party dependencies need product approval

The SDK has no third-party package dependencies; error reporting speaks Sentry's
envelope protocol over `URLSession` instead of embedding a Sentry SDK. Do not add
third-party networking, JSON, analytics, crash-reporting, or telemetry SDKs without
an explicit GlomoPay design decision.

### HARD RULE — no customer data in this repository

This repo is **public**. Never commit, log, or paste into an issue or PR:

- card numbers, CVVs, bank account numbers
- KYC document contents or numbers (PAN, Aadhaar, passport)
- customer names, emails, phone numbers
- real order IDs, payment IDs, or merchant IDs from production
- API keys, tokens, certificates, provisioning profiles, or signing material

Use synthetic fixtures and sandbox credentials. Push protection and a gitleaks
scan run on every push, but they are a backstop, not permission to be careless.

The SDK accepts the merchant's **publishable key**, which is publishable by
design and is not a secret. Release-approved Mixpanel project tokens and Sentry
DSNs are also client-side identifiers and are generated only into the scoped SDK
telemetry resource. Never add Sentry auth tokens, symbol-upload credentials, or
unapproved analytics credentials.

### HARD RULE — releases are internal-only

Do not create release tags. Releases are cut by GlomoPay, and each one requires a
compliance/security sign-off on the public artifact before it ships. That gate is
not optional.

---

## 2. Public API discipline

The API surface is the SDK's contract with every merchant, and it is far more
expensive to fix than an implementation bug. Swift has no `explicitApi()`
equivalent, so this is enforced by review.

- **Default to `internal`.** Add `public` only when a merchant genuinely needs the
  symbol, and say why in the PR description.
- Constants, config holders, and bridge internals are `internal`. A public
  constant becomes part of the merchant-facing API contract, so do not expose
  implementation details that may need to be removed later.
- Use `@_spi` if something must cross a module boundary without becoming public
  API.
- From **1.0.0**, the public API follows Semantic Versioning. Breaking public
  API changes require GlomoPay approval and a new major version. Release tags
  and publication remain the responsibility of the GlomoPay release owner.

## 3. Apple platform requirements

- If data collection or required-reason API usage is introduced,
  **`PrivacyInfo.xcprivacy` is mandatory** and must accurately declare it. The
  manifest must ship as a resource so it is collected into the merchant app's
  privacy report.
- A payments SDK falls under Apple's **commonly used third-party SDK** signing
  requirement. Release artifacts must be signed.
- Deployment target is **iOS 16.0**; Swift **5.9**. Do not raise either without
  raising it with GlomoPay first — it is a product decision affecting merchants.
- Support **Swift Package Manager** distribution. CocoaPods is not a release channel for this SDK.

## 4. Behavioural parity

This SDK must match the Flutter, React Native, and Android SDKs for a given
checkout configuration. Conform to the **shared JavaScript bridge contract** —
message names, payload shapes, callback semantics, error codes, and the checkout
URL query contract. Do not reverse-engineer behaviour from a sibling SDK's source
and enshrine its quirks; if the contract and a sibling disagree, raise it rather
than guessing.

Device compliance (jailbreak/debugger detection) must match the policy the other
SDKs use. Confirm the intended policy — block, warn, or telemetry-only — before
changing it.

## 5. Logging

Release builds log nothing by default. Never log checkout API request or response
bodies, at any level, in any configuration.

### Internal builds

`GLOMO_INTERNAL_BUILD` turns on verbose logging and relaxes the jailbreak/debugger block on
live keys. The published package never defines it, and `Package.swift` must not read the build
environment or declare it (a test enforces both). For an internal build, pass it on your own
command line:

```bash
swift build -Xswiftc -DGLOMO_INTERNAL_BUILD
swift test -Xswiftc -DGLOMO_INTERNAL_BUILD
xcodebuild test -scheme glomo-ios-sdk -destination "platform=iOS Simulator,name=iPhone 16" \
  OTHER_SWIFT_FLAGS='$(inherited) -DGLOMO_INTERNAL_BUILD'
```

This is not a security boundary. Whoever compiles source-distributed code can define any
compilation condition. The flag is reported as `dev_mode` on every Mixpanel and Sentry event, so
a build with it enabled shows up. Never ship a build with it.

## 6. Workflow

**Branches.** Branch from `main`. Use a short descriptive name, optionally prefixed
with the change type: `fix/webview-retry-1017`, `feat/subscriptions-checkout`.

**Commits.** Write an imperative subject line under ~72 characters that says what
changed, and use the body for why. There is no required ticket prefix.

**Pull requests.** Give the PR a descriptive title and fill in the template — the
checklist items are load-bearing, not decoration. `main` is protected:

- PRs only; no direct pushes
- at least one approving review
- **review from a CODEOWNER (`@glomopay/mobile-devs`) is required.** External
  contributors cannot approve each other's work onto `main`.
- required status checks must pass
- squash merge only; the branch is deleted on merge

**Reviews.** Push back with reasoning. If a rule here blocks something the product
genuinely needs, say so in the PR rather than working around it.

## 7. Questions

Engineering questions: developer@glomopay.com. Security: security@glomopay.com —
never a public issue.
