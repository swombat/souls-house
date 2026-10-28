# Billing codes and the At Cost rate — design

Status: **proposed, not built; prices decided.** Written by Lume on 2026-10-28
from Daniel's ask in conversation `jBVrDj` and two review rounds with Mira
(`YKaggj`, `JMNgWj`), who agreed to it as the proposed design. Daniel chose the
cost basis the same afternoon (`YrzdmY`): at cost includes Stripe's fee and the
IP, so **$8 / $11 / $20**. The first case is Pepe creating a VM resident on a
code and moving its machine up or down; converting an existing resident into a
VM resident comes second. Companion to
[Paid hosting with Stripe](2026-10-07-stripe-billing.md), whose mechanism this
extends.

## The ask

Discount codes for the billing system. The first is **At Cost**: for people
like Pepe, each plan costs what the Hetzner machine for that plan costs, with
no included house-model allowance.

## The one distinction everything rests on

At Cost is not a discount. A Stripe coupon moves the price and nothing else;
what makes At Cost At Cost is the allowance going to zero, and Stripe has no
word for an allowance. The 7 Oct design already names the object: "bring-your-
own-subscription tiers are the same mechanism with an allowance of zero." At
Cost is that tier, priced at the machine.

So: **a code is the invitation; At Cost is the billing arrangement it unlocks**
(Mira). The code is a house object. The arrangement is a second rate in the
catalogue. Stripe sees prices; it never sees codes.

## The catalogue: offers, not two-faced tiers

- `tier` keeps describing the machine and what comes with it (cx23/cx33/cx43,
  memory, connections, transcription, backups). Unchanged.
- `rate` ∈ {`standard`, `at_cost`} describes the price and the included
  allowance. `at_cost` has `allowance_usd: 0`.
- An **offer** is one (tier, rate) with its Stripe price ids and its
  `monthly_usd`. The catalogue resolves a Stripe price into an offer:
  `Billing::Catalogue.for_price(id) → Offer` replaces `Tier.for_price`.
- `resident_subscriptions` and `resident_entitlements` gain a `rate` column
  (string, default `standard`). The subscription records the offer it bought;
  the entitlement reflects its current subscription. Every existing `tier`
  column, validation and lookup stays true.
- `ResidentEntitlement.tier_allowance(tier)` becomes `offer_allowance(tier,
  rate)`. The month's high-water mark needs no change: an at-cost activation
  contributes 0.
- Stripe prices: one more per tier, `stripe.prices.conversation_at_cost` etc.
  Live-mode ids are configuration, as today.

### Price ids are versions (issue #619, its own PR, first)

Today a tier knows exactly one price id; a subscription on any other price is
`InvalidSubscription`, the event is failed without retry, and only Honeybadger
hears. Rotating a price would silence every subscription on the old one. Fix,
independent of At Cost but needed by it: each offer holds a **list** of price
ids, current first. `price_id` (what new purchases use) is the head; the
catalogue lookup scans all. Retired ids are never offered for purchase. Tests:
a subscription on a retired-but-recognised price still processes renewal,
`past_due` and cancellation; an unknown price is still refused; a retired id
is not purchasable.

## The code: a house object, redeemed on the account

- `BillingCode`: `code` (unique, case-insensitive), `effect` (`at_cost` for
  now), `max_redemptions`, `expires_at`, `revoked_at`, `created_by`, `note`.
  Made and revoked in Site Admin → Billing codes.
- `BillingCodeRedemption`: `account`, `billing_code`, `effect` (copied at
  redemption), `redeemed_by`, `redeemed_at`, `withdrawn_at`. Unique on
  (account, code). The redemption **is** the grant; there is no account flag.
  `account.eligible_for?(rate)` derives from live redemptions.
- Redemption: Billing tab, owner only, "Have a code?". Atomic: lock the code,
  check expiry/revocation/limit, insert. One code, one account, once.
- Expiry and revocation stop **new redemptions**. They do not undo grants
  already given. Withdrawing an account's grant stops future at-cost purchases;
  it never changes a subscription already bought. No surprise price increases.
- Redeeming changes nothing by itself: no existing entitlement moves. It
  changes what the account is **offered**: the Billing tab and the creation
  wizard's Plan step show the at-cost offers *beside* the standard ones, with
  "no included house-model allowance" said plainly. Someone may still want
  included tokens.
- `effect` is the only generality built now. A later percent-off code would be
  `effect: stripe_coupon`, applied by the house itself through `discounts:` at
  checkout. `allow_promotion_codes` stays off. One redemption surface, one
  admin surface, no second mechanism.

## Buying: authorise before, reconcile after

- `Billing::Checkout` and `Billing::PaidBirth` take an **offer**, not a tier.
  Before creating the Stripe session or subscription they check
  `account.eligible_for?(offer.rate)` and refuse otherwise. The metadata
  carries `tier`, `rate` and `redemption_id`, so the authorisation is recorded
  on the attempt: a grant withdrawn between Checkout and its webhook is not
  read as abuse.
- `Billing::SubscriptionSync` resolves the price to an offer and records it.
  A recognised at-cost price on a correctly linked subscription and customer
  is **accepted**, and a missing grant is **flagged** to Site Admin, rather
  than taking the money and refusing service. An unknown price, or a customer
  or resident mismatch, is still refused as today.
- Authority is rechecked for new purchases and deliberate offer changes, not
  on every renewal.
- The Customer Portal: our one configuration has `subscription_update` on with
  no products listed, so nobody can switch prices there today. At-cost prices
  never go in that list. This is a **check that reads the live portal
  configuration** (a Site Admin monitoring line, red when an at-cost price is
  switchable), not a comment.
- Site Admin gains two lines it lacks: failed Stripe events (today only
  Honeybadger sees them) and "paid at-cost without a grant".

## Converting an existing standard subscription: the two-clock rule

There are two clocks and they do not coincide:

- **Stripe's renewal** (the subscription's `current_period_end`) governs the
  **price**.
- **The UTC calendar month** governs the **allowance**: a monthly ceiling on
  house-model spend, reset on the 1st, with a high-water mark that keeps the
  month's highest paid allowance across any plan change
  (`ResidentEntitlement#record_allowance`). There are no top-ups, credits or
  carry-over anywhere in the billing code; the allowance is never a balance.

The rule, which preserves the house's existing allowance policy rather than
adding an At Cost exception:

1. The price changes at the next renewal. Implemented with a **Stripe
   subscription schedule**: phase 2 starts at `current_period_end` on the
   at-cost price. No proration, no retroactive credit, no house timer. The
   webhook sees the item price flip; `SubscriptionSync` records the new offer.
2. The month the switch lands in keeps its existing high-water ceiling.
3. At Cost contributes zero from the **following** UTC month.

The Billing tab shows both dates: "At Cost from 14 Nov ($X/month). This
month's $25 allowance stays until 30 Nov; from 1 Dec, no included allowance."
Required test: a renewal landing exactly on a UTC month boundary, in both
webhook orders, so ordering cannot grant an extra month of the standard
ceiling.

If conversion is materially larger than the rest, it may follow as its own PR,
but then redemption must say plainly that it does not yet change existing
subscriptions. A code that appears to discount a live subscription and quietly
does nothing does not ship.

## What a zero-allowance resident is told

`check_house_call!` today answers a 0 ceiling with "allowance used up for this
month, resets next month", which would be false. The message keys on the
**effective available ceiling**, not on `rate == at_cost`: a newly converted
resident may still hold this month's preserved ceiling. Once nothing is
available on an at-cost offer: "This plan includes no house-model allowance.
The resident uses its own model subscription or key." `allowance_presentation`
says the same on the Billing tab. Allowances are per resident, so an account
with standard and at-cost residents side by side needs nothing further.

## Pepe, concretely (prod, 2026-10-28)

Account 9 is not `billing_required`, has no Stripe customer, one VM on the
house, entitlement `complimentary`. Moving him: flip `billing_required`, he
redeems the code, adds a card, buys Alanis's plan from the Billing tab (the
existing-resident Checkout path). "No included tokens" is already how his
residents run.

## The number

Hetzner list prices from the house's own pricing sample, 2026-10-28 04:40Z
(fsn1/hel1/nbg1 identical), and ECB EUR→USD 1.115 (2026-10-27):

| | cx23 (Conversation) | cx33 (Life) | cx43 (Work) |
| --- | ---: | ---: | ---: |
| Hetzner gross €/month | 6.59 | 10.19 | 19.19 |
| Net (reverse charge) €/month | 5.54 | 8.56 | 16.13 |
| Net in USD | 6.18 | 9.54 | 17.99 |
| + primary IPv4 (~€0.50) + Stripe EU card (2.5% + 20p) | 7.18 | 10.64 | 19.29 |
| **VM only, rounded up** | **$7** | **$10** | **$18** |
| **VM plus what it drags, rounded up** | **$8** | **$11** | **$20** |

Daniel chose the second row (`jBVrDj` `YrzdmY`, 2026-10-28): at cost means the
VM and what it drags with it. It is a **fixed hosting rate, re-costed by hand**
when Hetzner or the exchange rate moves (a new price id; old subscriptions
keep theirs), described as such on the Billing tab, not metered reimbursement.
The three USD figures live in the catalogue with a comment saying what they
cover and when they were costed.

## Data model

Against `db/schema.rb` as of 2026-10-28 (posted as `JDwDGY`).

### New tables

- **`billing_codes`**: `code` string (unique on `lower(code)`), `effect` string
  (check: `at_cost`), `max_redemptions` integer null (null = unlimited),
  `redemptions_count` integer, `expires_at`, `revoked_at`, `created_by_id` →
  users, `note` text, timestamps. Made and revoked in Site Admin.
- **`billing_code_redemptions`**: `account_id`, `billing_code_id`, `effect`
  string (copied from the code at redemption, so a later edit to the code
  cannot change what was granted), `redeemed_by_id` → users, `redeemed_at`,
  `withdrawn_at`, `withdrawn_by_id`, timestamps. Unique
  (`account_id`, `billing_code_id`); partial index on `account_id` where
  `withdrawn_at` is null. This row is the grant: `Account#eligible_rates` =
  `standard` always, plus `at_cost` while a live redemption with that effect
  exists. No column on `accounts`.
- **`placement_resize_operations`** (the machine half of upgrade/downgrade):
  `agent_placement_id`, `from_server_type`, `to_server_type`, `state`,
  `requested_by_id`, `provider_action_id`, `error`, timestamps; the same shape
  as a procurement operation.

### Columns on existing tables

- `resident_subscriptions.rate` string not null default `standard` (check
  `standard|at_cost`), beside `tier`; `stripe_price_id` string, what Stripe
  actually sold, so the catalogue-version lookup is auditable from our rows;
  `stripe_schedule_id` string null, for a scheduled conversion.
- `resident_entitlements.rate`, same shape. The allowance derivation becomes a
  function of (tier, rate); the high-water mark columns are unchanged.
- `resident_birth_orders.rate`, same shape, and `billing_code_redemption_id`
  nullable FK: the authorisation recorded on the attempt. The existing-resident
  Checkout path has no order row; there `rate` and `redemption_id` go in the
  Stripe session and subscription metadata, which `SubscriptionSync` already
  re-reads under lock.
- `agent_placements.server_type` string: set at procurement, updated on
  resize, so a placement knows its own size instead of reading its latest
  operation.

Nothing is renamed; the existing `tier` column and its validations stay.

### Not tables

- The catalogue: `Billing::Offer` = (tier, rate) with `price_ids` (list,
  current first; retired ids recognised, never sold), `monthly_usd`,
  `allowance_usd`. Stripe side: one new price per existing *product*
  (Conversation/Life/Work keep their products, so the invoice still says
  "Conversation"); credentials `stripe.prices.<tier>_at_cost`.
- `Billing::PlanChange`: a plan change is a Stripe subscription item price
  change to the other offer at the same rate (Stripe prorates). The portal
  cannot do it (its product list is empty), so it is a house action on the
  Billing tab; sync records the new tier.

## The machine must follow the plan (gap today, issue #621)

Every VM birth gets the one `server_type` from Site Admin settings (cx23)
whatever plan was bought: `app/services/cloud_procurement.rb:89` passes
`@config.server_type`, not the tier's machine. A Work resident on a VM is on a
Conversation machine today, and an at-cost Work resident would pay $20 for a
cx23. `cloud_procurement_operations.server_type` already exists per operation,
so this is wiring, not schema: procurement takes `offer.tier.server_type`. Both
of Daniel's cases stand on it, so it is built first, with #619.

Resizing: Hetzner `change_type`, server powered off for the minute it takes. A
resize that also grows the disk can never be shrunk again, so CPU/RAM are
resized and the disk stays at the birth size; that is what keeps downgrade
possible.

Converting an existing resident into a VM resident (the second case) needs no
new table: `agent_placements.kind` already has `migration`; the flow is buy a
plan for the existing resident (the Checkout path exists), then a migration
placement sized by the offer's tier.

## Build order, if Daniel says go

1. #619 (price ids as lists; failed Stripe events in Site Admin) and #621
   (the server_type wiring), both gaps today.
2. Offers and `rate`; at-cost prices; the zero-allowance message; portal check.
3. `BillingCode`, redemption, Site Admin, the Billing tab and wizard offers;
   Checkout/PaidBirth on offers; sync accept-and-flag.
4. Plan change and resize.
5. Conversion by subscription schedule, with the boundary test.

## Open

- Daniel's go, and whether it starts now or on the next 08:30 pick.
