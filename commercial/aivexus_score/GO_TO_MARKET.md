# AIVEXUS Score — commercial checkpoint (12 Nov 2026)

## Decision
**No release until owner consent and acceptance tests.** First distribution
hypothesis: itch.io HTML5 playable donation (free/pay-what-you-want), Android
candidate later. This is a very crowded market; even free offline scorekeepers
exist, so conversion rates below are ONLY sensitivity examples, never forecasts.

Reference competitor (Google Play):
https://play.google.com/store/apps/details?id=com.pocket.scoreboard
This competitor already offers 2/4 players, names, match history, local saving.
Therefore AIVEXUS Score's v0.1 is a production and distribution experiment, not
yet a differentiated paid product. A paid-only launch is NOT recommended.

## Distribution choices
| Channel | Entry cost | Monetization | Constraints |
|---|---:|---|---|
| itch.io hosted HTML5 | No mandatory entry fee found | Optional donations | Browser embedded; HTML5 donations only; index.html ZIP, relative paths, payment setup and tax identity |
| itch.io downloadable | No mandatory entry fee found | Minimum price or pay-what-you-want | Users download/install; marketplace fees/payment processing |
| Google Play | US$25 one-off registration (needs owner approval) | Paid app, IAP, subscriptions | Identity verification, privacy/data safety, policies; for newer personal accounts closed test 12 testers/14 days |
| Direct/GitHub Releases | No mandatory upload fee for public repo | Separate donations/payments | Payments, taxes, support, updates and trust become publisher's burden |

Official: https://itch.io/docs/creators/payments
https://itch.io/docs/creators/html5
https://itch.io/docs/creators/pricing
https://support.google.com/googleplay/android-developer/answer/6112435
https://support.google.com/googleplay/android-developer/answer/14151465

Recommended FIRST payment model: free Web play plus voluntary support. No
advertising SDKs, subscriptions, recurring cloud fees or premium feature wall.
If demand exists, consider separately a downloadable €3-5 edition and Android
store later, never without approval. Google Play's service fee depends on
enrollment and transaction type; eligible initial tier is 15% on the first
US$1m revenue, not a blanket guarantee:
https://support.google.com/googleplay/android-developer/answer/112622

## Fees and sensitivity examples, not earnings predictions
For itch.io typical card processing assume 2.9% + 0.30 per payment and default
10% platform share. Currency conversions, taxes, refund fees and payout charges
are EXCLUDED. Figures below use a notional single currency and are approximate:

Payment 3.00 -> 3.00 * (1 - .10 - .029) - .30 = 2.31 before income/social taxes.
Payment 5.00 -> 5.00 * (1 - .10 - .029) - .30 = 4.06 before income/social taxes.
Payment 10.00 -> 10.00 * (1 - .10 - .029) - .30 = 8.41 before income/social taxes.

| Scenario | Downloads | Share donating | Mean contribution | Approx. proceeds after platform + card |
|---|---:|---:|---:|---:|
| None | 100 | 0% | 0 | 0 |
| Low test | 200 | 1% | 3.00 | 4.63 |
| Intermediate sensitivity | 1,000 | 2% | 5.00 | 81.10 |
| High sensitivity (NOT forecast) | 5,000 | 2% | 5.00 | 405.50 |

All examples exclude costs of the creator's work, French income/social taxes
and potentially VAT, exchange/withdrawal fees and refunds. Payment processor
rates vary by country/currency. For itch.io payout collection, its docs
describe a US$3 one-time tax-identity fee and possible payout fees. Even with
zero platform registration fee, break-even depends on those charges and actual
legal obligations. If minimum payable outlay were 3 units and all donations
were 5 units, ONE payment might cover the 3-unit fee, but that is NOT break-even
on development labor or business taxes.

## France/EU legal launch gate (requires qualified verification)
- Decide legal identity/entity and activity classification for selling software
  or receiving recurring monetized support. Micro-entreprise may be an option,
  but BIC/BNC classification and rates depend on actual activity.
- Check registration, URSSAF declarations (even zero revenue for active
  micro-enterprises), income tax, invoicing, VAT and intra-EU rules. Avoid
  assuming the marketplace automatically settles the publisher's own duties.
- Provide legally appropriate identity, contact, commercial terms, support,
  refund/withdrawal notices. Digital-content withdrawal exemptions have
  specific consent/acknowledgment conditions.
- Publish reviewed privacy notice and marketplace data-safety declarations.
  Verify release manifest, SDKs, remote fonts/renderer, browser storage and
  names/scores stay local. Hosting and payment providers have their own data.
- Review Flutter/package licenses, brand name availability, and ownership of
  any app icon or future assets before distribution.

Authorities:
https://entreprendre.service-public.gouv.fr/vosdroits/F23455
https://www.economie.gouv.fr/dgccrf/les-fiches-pratiques/delais-de-reflexion-ou-de-retractation-comment-sappliquent-ils
https://entreprendre.service-public.gouv.fr/vosdroits/F37353
https://www.economie.gouv.fr/entreprises/gerer-sa-micro-entreprise/micro-entrepreneur-auto-entrepreneur-quelles-sont-vos-obligations
https://www.cnil.fr/fr/applications-mobiles-votre-vie-privee-devra-etre-mieux-protegee

## Funding alternatives, not primary launch path
1. GitHub Sponsors for project maintenance if contributor eligibility is
   approved and the project is properly licensed/described: France supported,
   no GitHub fee on sponsorships from personal accounts. This is a channel for
   support, not proof of demand or a replacement for accounting.
   https://docs.github.com/en/sponsors/sponsoring-open-source-contributors/about-sponsorships-fees-and-taxes
2. Contract development or licensing genuinely reusable modules: potentially
   more revenue per client than voluntary donations, but scope/support/IP
   contracts need explicit approval. Never promise autonomous generation before
   proven.
3. Crowdfunding/pre-sales: NOT before a working build + realistic delivery
   schedule, because rewards create obligations and refund/support risks.
4. Bpifrance Bourse French Tech: possible later for a qualifying SME's genuine
   innovation project, not an automatic individual grant. Described ceiling
   EUR30k and partial coverage of qualifying innovation expenses; previous
   expenses excluded. Eligibility/application and co-funding must be checked.
   https://www.bpifrance.fr/catalogue-offres/bourse-french-tech
5. Stock-market investments: not a funding plan at zero capital. Illustration
   EUR1,000 at +5% = +EUR50 before fees/tax, but -30% = -EUR300; both hypothetical.
   In France the 2026 default PFU for relevant capital gains/investment
   proceeds is 31.4% (unless other options/exemptions apply). PEA has different
   conditional treatment after five years. Broker fees and risk of total loss
   also matter. No investment without user consent and capital/risk review.
   https://www.economie.gouv.fr/particuliers/impots-et-fiscalite/gerer-mes-autres-impots-et-taxes/comment-fonctionne-le-prelevement-forfaitaire-unique-pfu
   https://www.amf-france.org/fr/espace-epargnants/comprendre-les-produits-financiers/actions-obligations/actions/investir-en-actions-cotees-en-bourse

## Real metrics after authorization
Track by month: page views, download count, voluntary paying users, donation
gross, refunds, marketplace processing fees, taxes, withdrawable balance, actual
payout receipt, crash rate, support contacts. Keep raw financial records private.
Use marketplace-provided anonymous aggregates; no hidden user tracking.

## Current unblocked work and gates
- Develop isolated draft PR, tests, CI and cross-platform packaged candidates
- Review Web subpath correctness before itch.io preview; Flutter default root
  base href is not safe when embedded under a store CDN subdirectory
- Test on S24 FE and browser; no actual buyer/receipt exists yet
- Owner decisions: publishing identity, legal form, store account, payment
  processor, public listing, pricing, any Google Play registration fee
