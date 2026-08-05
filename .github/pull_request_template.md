## What and why

<!-- What changed, and why it needed changing. Link any relevant issue or discussion. -->

## How this was verified

<!-- iOS versions and devices/simulators tested. Attach the checkout flow if UI changed. -->

## Checklist

- [ ] No customer data in this PR — no real order IDs, payment IDs, customer names,
      emails, phone numbers, card numbers, bank account numbers, or KYC document
      contents in code, tests, fixtures, screenshots, or the description.
- [ ] No credentials — no API keys, tokens, certificates, provisioning profiles, or
      signing material. Sandbox keys only in tests.
- [ ] No new third-party dependencies. (See CONTRIBUTING.md — this is a hard rule.
      If you believe one is unavoidable, stop and open a discussion first.)
- [ ] Public API changes are intentional and minimal. New `public` symbols are
      justified in the description; anything internal is marked `internal`.
- [ ] No card entry, tokenization, or PAN handling added. (See CONTRIBUTING.md.)
- [ ] Release-build logging is off by default; no request or response bodies logged.
- [ ] `PrivacyInfo.xcprivacy` updated if data collection or required-reason API use
      changed.
- [ ] No version bump, no release tag, and no `pod trunk push`. Releases are cut by
      GlomoPay.
- [ ] CHANGELOG.md updated if merchant-visible behaviour changed.
