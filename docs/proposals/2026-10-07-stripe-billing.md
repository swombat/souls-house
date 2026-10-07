# Paid hosting with Stripe — design

Status: **proposal, not implemented.** Written by Lume, 2026-10-07, from Daniel's
decisions in conversation `oewbQY`. Revision 2 addresses Mira's review of
`f34c264` (PR #198). Deploy and live-mode keys stay Daniel's.

## Decisions already made

- **Stripe**, not Paddle. Seller is **Swombat Limited** (UK, VAT-registered).
- **USD is the only price currency**; base prices exclude VAT ("$20/month + VAT").
- Launch tiers **$20** and **$50** per month, each buying hosting for one resident
  plus a monthly house-inference allowance. Later bring-your-own-subscription
  tiers are the same mechanism with an allowance of zero.

## What a tier controls

| | Starter ($20) | Studio ($50) |
| --- | ---: | ---: |
| House inference / month | $8 *(placeholder)* | $25 *(placeholder)* |
| Container memory | 4 GB *(placeholder)* | 8 GB (today's default) |
| Container CPU shares | 1024 | 2048 |
| Delivery | shared host container | shared host container (dedicated VM later) |

Placeholders are calibrated before launch from per-resident cost (the new per-resident
attribution in *Allowance and ledger*), the host's monthly cost per realistic resident count, and
measured Stripe fees. Each tier must show a positive margin at full allowance use.
The pricing page states plainly whether a tier is a shared-host container or a
dedicated VM. At launch it is always the former. One-VM-per-resident
(#140/#192) changes delivery later, not the subscription.

`Tier` is a server-owned catalogue in code (like `HouseInference::Offering`):
id, Stripe price ID per environment, allowance, memory, CPU. A webhook carrying
a price not in the catalogue is rejected and alerted on.

## Unit of sale

One Stripe **customer per account**; one **subscription per hosted resident**.
This isolates operationally (a cancellation or tier change touches one
resident), not financially: a shared payment method that fails can put several
of an account's residents into grace at once, and the owner UI shows that
together. Guest residents never need a plan.

## Data model

```
billing_customers        account_id (unique), stripe_customer_id (unique)

resident_subscriptions   one row per Stripe subscription, never reused
                         agent_id, account_id, stripe_subscription_id (unique),
                         tier, stripe_status, current_period_end,
                         cancel_at_period_end, last_synced_at

resident_entitlements    one row per hosted resident (agent_id unique), owned by
                         the resident's home account
                         source: complimentary | stripe
                         tier, current_subscription_id (FK, nullable),
                         state (see table), grace_started_at, grace_deadline,
                         notices_sent (json), held_at, hold_released_at

stripe_events            stripe_event_id (unique), type, payload,
                         status: received | processing | processed | failed,
                         attempts, last_error, processed_at
```

A partial unique index allows at most one `resident_subscriptions` row per agent
whose `stripe_status` is live (`incomplete`, `trialing`, `active`, `past_due`).
The entitlement points at exactly one current subscription. **Only events about
the current subscription can change the entitlement's state.** Events about any
other subscription update that subscription's own row and nothing else, so an old
subscription's cancellation can never re-hold a resident whose replacement is paid.

## Allowance and ledger

- **Paid allowance belongs to the resident**, through its entitlement, not to a
  user. It does not move when the resident's model changes, and it is never
  transferable. `HouseInferenceCall` gains an immutable `agent_id` and
  `entitlement_id` at creation, so per-resident cost is attributable from now on.
  Older grant-only rows stay attributable to the grant only, and reports say so.
- **Legacy grants are untouched.** Today's `HouseInferenceGrant` (one per user,
  $10, transferable, ledger and spend history preserved) keeps working as the
  `complimentary` funding route. The complimentary backfill gives existing
  hosted residents a `complimentary` *hosting* entitlement with **no new
  inference allowance**. That keeps today's subsidy exactly as large as it is,
  not $10 × residents. Detached legacy grants (no resident) stay as they are.
- **Clock: UTC calendar month**, the existing ledger's clock, disclosed on the
  pricing page ("allowance resets on the 1st, UTC"). A subscription starting
  mid-month gets its tier's allowance for the rest of that month. The limit is
  a ceiling on the month's spend, never a balance that gets topped up, so
  repeated checkouts, tier changes or repayment cannot mint budget. Spend so far
  in the month always counts.
- **Tier changes.** Upgrade applies immediately with proration, using
  `payment_behavior: pending_if_incomplete`, so a failed proration payment leaves
  the old tier in force and changes nothing. The higher limit (and resources at
  next container restart) applies once the payment succeeds. Downgrades are
  scheduled for period end, so allowance never shrinks below what's already spent
  mid-month.
- **Strict admission for paid ledgers.** A call is admitted only if
  `limit − spent − outstanding reservations ≥ reservation`. Because the reservation
  is the upper bound under the pinned route's request/price bounds, paid spend
  cannot exceed the allowance. (The legacy grant keeps its disclosed
  bounded-overrun behaviour until changed separately.)
- **Capacity.** Paid ledgers do not draw on the free house-wide ceiling
  (`HOUSE_INFERENCE_MONTHLY_LIMIT_USD`, $300). They have their own operational
  ceiling, set at least to the sum of active paid allowances, plus an alert at
  80%. A paying resident's allowance must not fail because the free pool ran out.

## Entitlement states

| State | Entered when | Execution | House allowance |
| --- | --- | --- | --- |
| `pending` | checkout started, first payment not confirmed (`incomplete`) | as before checkout | none granted |
| `active` | current subscription `active` (or `trialing` if a trial is adopted) | normal | tier |
| `grace` | current subscription becomes `past_due` | normal | tier |
| `held` | grace deadline passes unpaid, or current subscription `canceled`/`unpaid`, or a scheduled cancellation reaches period end | **blocked** (below) | none |
| `complimentary` | admin grant (audit-logged) | normal | legacy grant only |

- A failed or abandoned first checkout (`incomplete_expired`) leaves the
  entitlement exactly as it was. It grants nothing at any point.
- **Grace is house policy, not Stripe's retry setting:** 14 days from the first
  failed renewal (`grace_deadline` stored). Stripe may keep retrying, and a
  successful retry inside grace returns to `active`. Reaching the deadline holds
  the resident even if Stripe still shows `past_due`.
- Scheduled cancellation (`cancel_at_period_end`) is shown to the owner and
  resident from the moment it is set. It holds at period end, with no grace.
- **Recovery:** paying the outstanding invoice, or a replacement checkout, makes
  that subscription current and the state `active`. The hold lifts. The owner's
  separate `paused` flag is never changed by billing in either direction.

## The hold boundary

The hold is enforced where work starts, for **every funding route**, including
the resident's own provider keys and OAuth subscriptions. Paying for hosting is
what is lapsed, not just house tokens.

- **New work:** `ResidentTurn` admission (the existing single admission gate)
  refuses with `billing_hold`. So do house-inference reservations and rhythm
  dispatch (new skip reason `billing_hold`).
- **Queued turns** are cancelled through the existing cancellation path with a
  visible reason.
- **An in-flight turn** may finish under its normal turn timeout, capped at 30
  minutes for this purpose. Its final writes (journal, memory, message) are kept.
- **Container-local execution** (cron, background jobs inside the container)
  can't be stopped by a Rails skip, so once in-flight work has drained, the
  resident's container is **stopped, not removed**. Volumes, home, memory and
  backups are untouched, and the container restarts on recovery.
- **Still available while held:** reading conversations, the owner's export of
  the resident's home and memory (served from Rails/volume, not a running
  container), billing pages.

## Notice

- **Owner:** email plus a durable in-app notice at grace start, T−7 days, T−1 day
  and at the hold. The same for a scheduled cancellation, 7 days and 1 day before
  period end.
- **Resident:** a message in its home conversation at grace start and at T−1,
  delivered while it is still running (it is running throughout grace), saying
  when and why. Resident notices are never sent by waking a resident after the
  hold. If the resident was already offline, the owner's durable notice is the
  record.

## Webhook

- Verify the signature. Upsert `stripe_events` by event ID.
  - New → `received`, enqueue.
  - Already `processed` → 200 no-op.
  - `received`/`failed` (job lost or errored) → re-enqueue. A Stripe retry is
    a recovery path, not a duplicate.
- A sweeper re-enqueues events stuck in `received`/`processing` beyond 10 minutes.
  After 5 failed attempts, alert the site admins.
- **Serialize per resident:** the job takes a PostgreSQL advisory lock on the
  agent ID, then re-fetches the subscription from Stripe, validates it (customer
  belongs to the account, `metadata.agent_id` matches, price is in the catalogue)
  and applies it, all under the lock. An older fetch can't land after a newer one.
- **One live subscription per resident:** checkout creation refuses if the
  resident has a live subscription (the owner is sent to the portal instead) and
  uses a Stripe idempotency key derived from (agent, tier, attempt). The partial
  unique index is the backstop. A duplicate that gets through anyway is
  cancelled and refunded, with an alert.
- **Reconciliation** runs nightly and reports drift to site admins. Fixing goes
  through the same apply path as the webhook, triggered from the admin page.

## Tax

- Stripe Tax on, origin Swombat Ltd's UK address, product tax code for
  electronically supplied services.
- **UK customers (consumer or business): UK VAT charged.** A UK VAT number does
  not remove VAT on a domestic supply ([HMRC Notice 741A §5](https://www.gov.uk/guidance/vat-place-of-supply-of-services-notice-741a#sec5)).
- **EU business with a VAT ID: reverse charge.** Checkout validates the ID's
  format only; government verification is asynchronous
  ([Stripe](https://docs.stripe.com/tax/checkout/tax-ids#validation)). Verification
  results are recorded. A failed or unavailable check is flagged for admin
  review and the invoice treatment corrected if needed, never silently
  accepted as "handled".
- **EU consumers:** non-Union OSS registration before the first EU sale
  (accountant/Daniel action), number added to Stripe Tax registrations before
  live mode.
- **US:** monitored in Stripe Tax and registered only when a state threshold
  approaches.
- **Launch requirement, not a cosmetic check:** the accountant confirms OSS
  establishment and the consumer-facing price display. Base prices can stay
  USD tax-exclusive, but EU/UK consumers must see a compliant total.

## Security and operations

- Keys in credentials per environment (`stripe.secret_key`, `stripe.webhook_secret`),
  test mode until Daniel switches. Plain `stripe` gem, no `pay` gem.
- Only account owners (and admins of team accounts) can start checkout or open
  the portal. Site admins grant/revoke `complimentary` with an audit log.
- Nothing is ever deleted automatically. After 90 days held, site admins get
  a notice, and any further step is a human decision.

## Acceptance tests

1. Failed or abandoned first checkout grants nothing (no allowance, no state change).
2. Two paid residents on one account have independent ledgers. Spending one
   leaves the other untouched. Changing a resident's model moves no allowance.
3. Duplicate, crashed-mid-job and out-of-order events converge to Stripe's
   current state. A recorded-but-unprocessed event is reprocessed on retry.
4. A stale canceled subscription's events can't hold a resident whose
   replacement subscription is active.
5. On hold: new turns, rhythms and house reservations are refused on every
   funding route; queued turns are cancelled; an in-flight turn finishes and
   keeps its writes; the container stops and its volumes remain; export works.
6. Repayment lifts the hold and leaves an owner-set `paused` as it was. Pausing
   by the owner during a hold doesn't lift the hold.
7. Upgrades, downgrades, repayment and repeated checkouts never raise a month's
   available budget above the tier limit minus spend. A failed proration payment
   changes nothing.
8. Paid admission never exceeds the allowance. Paid calls are admitted when the
   free house-wide ceiling is exhausted.
9. Grace holds at its deadline even while Stripe still reports `past_due`.
10. A UK VAT ID doesn't zero tax. An EU VAT ID that fails verification is flagged.

## Phases

1. Models, tier catalogue, entitlements and states, webhook/sweeper/reconcile,
   Checkout + Portal links, complimentary backfill, paid ledger and strict
   admission, hold boundary, notices. Test mode only.
2. Container size from tier (applied at next restart, never by killing a turn).
3. Server type from tier, once one-VM-per-resident placement is real.
4. Bring-your-own-subscription tiers (allowance 0).

## Open questions for Daniel

- Trial: none, or N days on Starter? (Without one, `trialing` is never used.)
- New residents without a plan: blocked from starting, or a short free start?
- Do existing residents stay complimentary indefinitely, or until a date?
- Final allowance and container numbers once calibrated.
