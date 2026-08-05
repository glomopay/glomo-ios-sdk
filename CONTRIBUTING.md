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

### Dependencies — keep them few, get additions reviewed

Anything declared in `GlomoPaySDK.podspec` becomes a **transitive pod in the
merchant's Podfile**, where it can collide with their own version of the same
library. CocoaPods has no isolation mechanism for that, and SwiftPM resolution has
the same problem by a different route. So the bar is higher here than in an app and
the default is to use the platform.

It is **not** a ban. Hand-rolling a well-solved problem — especially a
security-sensitive one — wastes time and usually produces something worse. Reach for
a library when it genuinely earns its place.

**No discussion needed:** Apple's own frameworks and the Swift standard library.
This SDK currently uses Foundation, UIKit and WebKit with a `URLSession`-based API
client, and has zero pod dependencies.

**Propose before you build:** anything else. Raise it in the PR description, or in an
issue if it's large, with a short case for why. A CODEOWNER approving the PR is what
makes it accepted — so don't land a big piece of work that depends on a dependency
nobody has agreed to yet.

What reviewers will weigh:

- Does the platform already do this acceptably?
- Is the problem genuinely fiddly or security-sensitive — jailbreak/tamper detection,
  cryptography, parsing untrusted input? Those favour a maintained library over our
  own code.
- Maintenance health: recent releases, responsive to CVEs, more than one contributor.
- **License compatibility.** Must be redistributable under Apache-2.0 into
  closed-source merchant apps. Anything copyleft (GPL / LGPL / AGPL) is a no.
- Binary size and, if it ships as a static framework, symbol-collision risk.
- Collision likelihood: how commonly do host apps already depend on this, and at what
  versions?
- Pin an exact version in the podspec and `Package.swift`, and keep the two in sync.

**Still a hard no, regardless of review:**

- Anything that collects data or phones home — analytics, crash reporting,
  attribution, advertising. Those make us a data processor inside someone else's app,
  and they are the category most likely to collide with what the merchant already
  runs. The React Native SDK deliberately calls Segment's REST API rather than
  bundling the native SDK, precisely to avoid "conflicts with merchant's own Segment
  implementation" — that reasoning still holds.
- Anything that touches card data, tokenization, or native 3DS. See the card-handling
  rule above.

### HARD RULE — no customer data in this repository

This repo is **public**. Never commit, log, or paste into an issue or PR:

- card numbers, CVVs, bank account numbers
- KYC document contents or numbers (PAN, Aadhaar, passport)
- customer names, emails, phone numbers
- real order IDs, payment IDs, or merchant IDs from production
- API keys, tokens, certificates, provisioning profiles, or signing material

Use synthetic fixtures and sandbox credentials. Push protection and a gitleaks
scan run on every push, but they are a backstop, not permission to be careless.

Note that the SDK legitimately ships a Segment **write key** and accepts the
merchant's **publishable key**. Both are publishable by design and are not
secrets. Everything else is.

### HARD RULE — releases and `pod trunk push` are internal-only

Do not bump `spec.version`, do not create release tags, and never run
`pod trunk push`. Releases are cut by GlomoPay, and each one requires a
compliance/security sign-off on the public artifact before it ships. That gate is
not optional and has been missed once already on this SDK.

**CocoaPods Trunk is append-only.** A published version cannot be deleted or
overwritten — removal requires CocoaPods maintainer intervention and is not
guaranteed. An accidental push of a broken version is permanent and public.
Treat every publish as irreversible, because it is.

---

## 2. Public API discipline

The API surface is the SDK's contract with every merchant, and it is far more
expensive to fix than an implementation bug. Swift has no `explicitApi()`
equivalent, so this is enforced by review.

- **Default to `internal`.** Add `public` only when a merchant genuinely needs the
  symbol, and say why in the PR description.
- Constants, config holders, analytics plumbing, and bridge internals are
  `internal`. `GlomoPayAnalytics.defaultWriteKey` is currently `public`, which
  makes removing it a breaking change — that is the mistake to learn from, not
  copy.
- Use `@_spi` if something must cross a module boundary without becoming public
  API.
- The SDK stays on **0.x until GlomoPay freezes the API.** Propose breaking
  changes freely while pre-1.0; do not tag 1.0.0 yourself.

## 3. Apple platform requirements

- **`PrivacyInfo.xcprivacy` is mandatory.** The SDK collects analytics and device
  information, so it needs a privacy manifest declaring collected data types and
  required-reason API usage. Without it, merchant app submissions are rejected with
  this SDK named in the rejection. It must ship as a resource so it is collected
  into the merchant's app privacy report.
- A payments SDK falls under Apple's **commonly used third-party SDK** signing
  requirement. Release artifacts must be signed.
- Deployment target is **iOS 15.0**; Swift **5.9**. Do not raise either without
  raising it with GlomoPay first — it is a product decision affecting merchants.
- Support both **SwiftPM** and **CocoaPods**. `Package.swift` and
  `GlomoPaySDK.podspec` must stay in sync; a change to source layout affects both.
- `spec.version` must always equal the git tag.

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
