# AIVEXUS Score — isolated commercial pilot (v0.1)

**Status: source candidate, not approved for public sale or external release.**
Project goal: transform the Cantiere's demonstrated Flutter counter production
pattern into a genuinely useful, local-only, testable scorekeeper. This is a
**human-authored deterministic product MVP**; it is not evidence that the
AI-driven Cantiere can produce arbitrary commercial apps autonomously.

## Scope
- 2 configurable participants, nonnegative score +1/-1, confirmation before reset
- Undo history for 30 score changes, including reset
- Local persistence of scores, names and undo history via shared_preferences
- Interface text in Italian, English, French and Spanish (device locale)
- Responsive Material UI for Android and browser, no advertisements or telemetry
- No account, remote data, cloud runtime or API key

## Building and testing
GitHub Actions workflow: .github/workflows/commercial-score.yml. It creates
a **standalone** Flutter scaffold in a temporary runner directory; no root
lib/, pubspec.yaml, AIVEXUS runtime or other active workstream is changed.

Flutter 3.47.5, Java 17:
1. flutter create --platforms=android,web --org=dev.aivexus --project-name=aivexus_score <temporary-folder>
2. Copy this directory's pubspec.yaml, lib/ and test/ to that scaffold.
3. flutter pub get
4. flutter analyze
5. flutter test
6. flutter build web --release
7. flutter build apk --release

CI packages an Android APK and a browser ZIP with SHA-256 hashes. These are
**test artifacts only**, not signed/approved store releases. CI does not deploy,
publish, collect money, alter production or ask for credentials.

## MVP acceptance criteria (stop-ship if false)
- [ ] CI passes on the exact PR commit SHA (analyze, model/widget tests, web build, APK).
- [ ] The real app launches and works on Galaxy S24 FE.
- [ ] Hosted browser ZIP loads from a subdirectory and works in tested browsers; no claim that file:// works.
- [ ] Scores do not go negative; undo, reset confirmation and rename work.
- [ ] State survives app close/reopen; storage failure is visibly reported.
- [ ] No crash during 100 fast score taps and 20 resets/undo cycles.
- [ ] No unintended permissions, telemetry, remote network calls or ad SDKs.
- [ ] Accessible enough for basic use (labels, contrast, touch targets).
- [ ] Owner confirms identity, rights/licenses, legal/privacy texts, payment
      configuration, pricing and platform readiness before any publication.

## Go-to-market hypothesis (not a sales claim)
Start with a downloadable browser ZIP or playable HTML5 version on itch.io,
free/pay-what-you-want, after owner authorization and legal onboarding.
Android Google Play comes later if there is demonstrated demand and an
authorized $25 registration budget. The underlying tool is deliberately small
and crowded; measure real usage/donations before adding new modules.

## Commercial tracking (no personal telemetry required)
After distribution is authorized: record monthly store page views (if provided),
downloads, voluntary payments, platform processing fees, refund amounts, and
real payout receipts. Keep any financial dashboard private. Success requires a
**verified actual payout**, not an expected or simulated revenue figure.

## Isolation
All product sources live in commercial/aivexus_score/; the only other path
is its own isolated CI workflow. No edits to Windows Computer Use, Genesis,
Aivexus Web or the primary app. See PRIVACY.md.
