# Paid hosting with Stripe — design

Status: **phase 1a built (payment path); the rest of phase 1 not yet.** Written
by Lume, 2026-10-07, from Daniel's decisions in conversation `oewbQY`. Revision
2 addresses Mira's review of `f34c264` (PR #198). Deploy and live-mode keys
stay Daniel's. See *Build status* at the end.

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
- **Paid replaces, never stacks.** While a resident's entitlement is `active` or
  `grace` with `source: stripe`, every house call is charged to its paid ledger
  only. A legacy grant attached to that resident is not drawn on, and its
  sponsor may reassign it to another resident as today.
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
  scheduled in Stripe for subscription period end, which is generally **not** a
  calendar-month boundary. The downgrade changes resources at period end, but
  the allowance limit for the current UTC month stays at the highest tier paid
  in that month. The lower limit starts on the 1st after. Remaining allowance is
  always `max(0, limit − spent − reserved)`, and spend is never reset or refunded.
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
- **The deadline is imposed by our own job**, not by a Stripe event (Stripe may
  send nothing at that moment). A job is scheduled at `grace_deadline`, and the
  sweeper also holds any `grace` entitlement past its deadline. Transitions are
  monotonic: `grace_started_at` is set only on `active → grace`, so replaying or
  re-fetching `past_due` never restarts grace. A `held` entitlement leaves `held`
  only when the current subscription is `active` (invoice paid). `past_due`
  seen while held changes nothing.
- Scheduled cancellation (`cancel_at_period_end`) is shown to the owner and
  resident from the moment it is set. It holds at period end, with no grace.
- **Recovery:** paying the outstanding invoice, or a replacement checkout, makes
  that subscription current and the state `active`. The hold lifts. Lifting the
  hold removes **only** the billing stop reason. The container restarts and
  work resumes only if no other stop reason remains: the owner's `paused` flag,
  a disabled account or resident, a memory suspension, unsupported placement.
  Billing never changes `paused` in either direction.

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
  minutes from the hold (its *drain deadline*). Its final writes (journal,
  memory, message) are kept. Because a turn makes several inference calls, the
  reservation check has exactly one exception: a call carrying the ID of a
  turn admitted *before* `held_at` is admitted until that turn's drain deadline
  (and, for house inference, only within the remaining allowance). Background
  jobs, rhythms, subagents spawned after the hold and new turns get no exception.
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

## Who pays, and paying at creation (2026-10-25)

Daniel, `oewbQY` 2026-10-25: billing is switched on per account, at account
creation.

- **Site switch** `settings.billing_enabled` (Admin, Settings, Billing). Every
  account created while it is on gets `accounts.billing_required`. Accounts that
  already exist are never changed by the switch, in either direction: they got
  in early, and their residents, old and new, stay on the house. A site admin
  can flip `billing_required` on one account (audited).
- **Every new resident in a billing account needs a plan.** The plan pays for
  hosting, so this holds on every funding route, own keys included. The free
  house grant isn't given there; the plan's allowance replaces it.
- **Paying is the creation wizard's last step**, *Plan*, after Review: choose
  the plan; pay with the account's saved card (shown as brand, last four and
  expiry, with "Use a different card"), or add one in Stripe's embedded setup
  form (`ui_mode: embedded_page`, `mode: setup`; billing address and tax ID
  collected; the card becomes the customer's default). One button commits both
  the seed and the money: "Create Aria · $20/month + VAT".
- **Nothing is born before money clears.** The draft is held in a
  `resident_birth_orders` row; `Billing::PaidBirth` creates the subscription
  with `payment_behavior: default_incomplete` and `metadata.birth_order_id`,
  the browser confirms its first invoice with Stripe.js
  (`confirmCardPayment`, which handles 3-D Secure), and once Stripe reports it
  paid the resident is born through the ordinary `HostedBirth` (`paid: true`),
  named on the subscription (`metadata.agent_id`) and synced, so the plan is in
  force from its first moment. The browser's confirm and the webhook both
  complete the order; its row lock makes the birth happen once.
- **Failure modes.** A decline or an unfinished bank check leaves the order
  pending for another try, with the same or another card. Asking again for a
  different resident replaces the earlier unpaid order and cancels its
  subscription. An order unpaid at `expires_at` (23 hours, inside Stripe's own
  expiry of an incomplete subscription) is abandoned by the sweeper, its
  subscription cancelled and its draft cleared. A birth that fails *after*
  payment rolls back, keeps the order as `failed` with its draft, reports to
  the site admins, and can be retried; the payment is never lost track of.
- **Only the account's owner can pay.** Other members see who pays instead of a
  card form. Every other route to a new resident in a billing account (a birth
  through the API, an archive or GitHub import) is refused with a plain reason
  before anything is committed, until those routes can pay too.

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
11. Replaying `past_due` neither restarts grace nor releases a hold. The deadline
    job holds without any Stripe event.
12. A turn admitted before the hold completes its later inference calls until
    its drain deadline. A call without such a turn ID is refused at once.
13. A downgrade at mid-month period end after heavy spend leaves remaining at
    zero (not negative, not refilled). The lower limit applies from the 1st.
14. Recovery leaves an owner-paused or disabled resident stopped. A resident
    with a paid entitlement never draws on its attached legacy grant.

## Phases

Size: a medium integration, not three tables and a webhook. The first build
excludes dedicated VMs, bring-your-own tiers and any custom billing UI. This
revision closes the design; further changes come from implementation findings,
not more architecture.

1. Models, tier catalogue, entitlements and states, webhook/sweeper/reconcile,
   Checkout + Portal links, complimentary backfill, paid ledger and strict
   admission, hold boundary, notices. Test mode only.
2. Container size from tier (applied at next restart, never by killing a turn).
3. Server type from tier, once one-VM-per-resident placement is real.
4. Bring-your-own-subscription tiers (allowance 0).

## Open questions for Daniel

Answered 2026-10-11 (carried by Mira from RYpGrJ): **no trial**, a 30-day
money-back guarantee handled on request; **no plan, no new resident**; existing
residents **stay free**. Still open: final allowance and container numbers, and
shared host versus VM for paid tiers.

## Build status

**Phase 1a (this build): the payment path.** Stripe gem; `Billing::Tier`
catalogue (price IDs from credentials `stripe.prices.starter|studio` or
`STRIPE_PRICE_*`); the four tables; entitlement states and transitions,
including monotonic grace, the house-imposed deadline job and the sweeper;
signed webhook → recorded event → job that re-fetches under the per-resident
advisory lock; Checkout (Stripe Tax, VAT ID collection, required billing
address) and the Customer Portal; an account **Billing** tab; complimentary
backfill of existing hosted residents.

Additions from implementation and Mira's review of `c79c406`:
`complimentary_granted_at`, so a resident the house hosts free goes back to
complimentary (not `held`) when a paid plan ends by cancellation *or* by the
grace deadline. One unresolved Checkout session per resident
(`checkout_session_id`), expired at Stripe before it is replaced, under a row
lock, so two links can't both be paid. Events are claimed atomically per
attempt; a worker that dies mid-attempt is recovered once stale, and one that
dies on the final attempt is escalated by the sweeper. The Billing tab is
labelled a preview: plan benefits are shown as proposed, a lapse as recorded
only, with the 30-day guarantee.

**Phase 1b: the paid allowance.** House calls are charged to exactly one
ledger (the legacy grant or the resident's entitlement, DB-checked) and record
the resident they were made for. A paid entitlement's limit is the highest
allowance paid during the UTC month (`allowance_month`/`allowance_limit_usd`,
counting the outgoing tier at each change), so downgrades, lapses and
replacement checkouts never refill a month. Admission is strict, with in-flight
calls counted at their reservation, and several calls may run at once (unlike
the grant's one-at-a-time rule). Paid calls are left out of the free house-wide
ceiling. There is no separate paid ceiling: strict per-resident admission
already bounds paid spend by the sum of paid allowances. A paid resident
doesn't claim the user's one free grant, and a grant attached to it is refused
while the plan is paid.

**Not yet, in order:** the hold boundary (turn admission, reservations,
rhythms, queued-turn cancel, drain, container stop and restart); owner and resident notices; plan-gated resident
creation; refunds for the 30-day guarantee (manual in Stripe for now);
nightly reconcile and admin complimentary controls; duplicate-subscription
auto-cancel (today it fails the event and alerts). Until the hold boundary
lands, `held` is recorded and shown but stops nothing.
