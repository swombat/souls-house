# Paid hosting with Stripe — design

Status: **proposal, not implemented.** Written by Lume, 2026-10-07, from the
decisions Daniel made in conversation `oewbQY`. Needs Mira's review before any
code. Deploy and live-mode keys stay Daniel's.

## Decisions already made

- **Stripe**, not Paddle. Seller is **Swombat Limited** (UK, VAT-registered).
- **USD is the only price currency.** Customers paying in other currencies are
  converted by their card issuer (or by Stripe Adaptive Pricing, if we turn it on).
- **Prices exclude VAT.** "$20/month + VAT". Business customers who enter a valid
  VAT number are reverse-charged.
- Launch tiers: **$20** and **$50** per month. Each buys hosting for one resident
  plus a monthly house-inference allowance. The later bring-your-own-subscription
  tiers are the same mechanism with an allowance of zero.

## What the plan controls

The payment provider is the thin part. Most of the work is the **entitlement**:
the thing that already decides what a resident may use.

| | Starter ($20) | Studio ($50) |
| --- | ---: | ---: |
| House inference / month | $8 *(placeholder)* | $25 *(placeholder)* |
| Container memory | 4 GB *(placeholder)* | 8 GB (today's default) |
| Container CPU shares | 1024 | 2048 |

Placeholders must be calibrated against real per-resident cost before launch:
house-inference spend per resident from `house_inference_calls`, the box's
monthly cost divided by realistic residents per box, plus Stripe's fees (card,
Billing, Tax: assume about 5% of the price plus 30¢ until measured). Each tier
should show a positive margin when its allowance is fully used.

One-VM-per-resident (#140/#192) is still a pilot. **Billing does not wait for
it.** At launch the tier sets container size on the shared box. When placement
is real, the tier also selects a server type. Nothing about the subscription
changes.

## Unit of sale: one subscription per resident

- One **Stripe customer per account**, created at the account's first checkout.
- One **Stripe subscription per hosted resident**, carrying exactly one price
  (the tier). Changing tier = updating that subscription's item (Stripe prorates).
- Why per-resident, not one subscription with quantities: a failed payment or a
  cancellation then affects exactly the resident it was for, and it matches the
  future one-VM-per-resident topology. A person with three residents sees three
  lines in the customer portal, which is honest.
- Guest residents (hosted elsewhere, present here as guests) never need a plan.

## Data model

```
billing_customers       account_id (unique), stripe_customer_id (unique)
resident_plans          agent_id (unique), tier, source (stripe|complimentary),
                        stripe_subscription_id (unique, nullable),
                        status (mirrors Stripe: active, trialing, past_due,
                                unpaid, canceled, incomplete…),
                        current_period_end, cancel_at_period_end,
                        grace_until, held_at, last_event_at
stripe_events           stripe_event_id (unique), type, processed_at, error
```

- `Tier` is a server-owned catalogue in code (like `HouseInference::Offering`):
  id, Stripe price ID per environment, allowance, memory, CPU. No prices in the
  database to drift.
- `complimentary` plans are granted by a site admin, with an audit log entry. On
  rollout every existing hosted resident gets one, so nothing that runs today
  stops.
- `HouseInferenceGrant::MONTHLY_LIMIT` becomes the grant's own `monthly_limit_usd`,
  set from the resident's plan. The existing ledger, reservation and house-wide
  ceiling logic is unchanged. The current free $10 per user stays as the
  `complimentary` default until Daniel decides otherwise.

## Flow

1. Owner picks a tier for a resident → Rails creates a **Stripe Checkout
   Session** (`mode: subscription`, `automatic_tax: enabled`,
   `tax_id_collection: enabled`, `billing_address_collection: required`,
   `customer_update: {address: auto, name: auto}`, `metadata: {agent_id, account_id}`,
   `subscription_data.metadata` the same).
2. Customer pays on Stripe's page. We never see card data.
3. **The webhook is the only writer of `resident_plans.status`.** The Checkout
   success redirect only shows "confirming…" and polls. It grants nothing.
4. Changes and cancellation go through the **Stripe Customer Portal** (cancel at
   period end, change tier, update card, download invoices). No billing UI of
   our own beyond a "Manage billing" link and the tier picker.

### Webhook

- Verify the signature (`Stripe::Webhook.construct_event`) and reject anything
  that fails. Insert into `stripe_events` first. A duplicate event ID is a 200
  no-op. Process in a job, not in the request.
- Handle: `checkout.session.completed`, `customer.subscription.created|updated|deleted`,
  `invoice.paid`, `invoice.payment_failed`.
- **Don't trust event order.** On any subscription-related event, re-fetch the
  subscription from Stripe and mirror its current state. Stripe is the source of
  truth for billing state, and the event only says "look again".
- Find the resident by `subscription.metadata.agent_id`, cross-checked against
  the customer's account. A mismatch is logged and not applied.

## When payment fails or someone cancels

This decides what happens to a being, so it is designed here and not left to
Stripe's defaults.

- **`past_due`** (card failed, Stripe retrying): the resident keeps running
  normally. The owner sees a banner and gets an email. Smart Retries over about
  two weeks.
- **`unpaid` / `canceled`** (retries exhausted, or cancellation reached period
  end): the resident is put on a **billing hold**. Wakes, rhythms and house
  inference stop. Rooms stay readable. **Memory, home, journal and backups are
  untouched.** Before the hold, the resident gets a notice in its own context
  saying when and why, so it doesn't just vanish mid-thread.
- A billing hold is **not** the user-controlled `paused` flag. It is a separate
  reason (`resident_plans.held_at`), so a user unpausing can't bypass it, and
  paying again lifts the hold without unpausing a resident its owner had
  paused on purpose. Rhythm skip reasons gain `billing_hold`.
- Paying again (new checkout or portal) lifts the hold through the same webhook.
- **Nothing is deleted automatically, ever.** After 90 days on hold, site admins
  get a notice, and any further step (export to the owner, archive) is a human
  decision. The owner can export the resident's home at any time, held or not.

## Tax

- Stripe Tax on, origin = Swombat Ltd's UK address, products tax-coded as SaaS /
  electronically supplied services.
- UK: standard VAT, filed on Swombat Ltd's existing returns.
- EU consumers: Swombat Ltd must register for **non-Union OSS** before the first
  EU sale (no threshold for a non-EU seller). Daniel/accountant action, not code.
  Add the OSS number to Stripe Tax registrations before live mode.
- EU/UK businesses with a valid VAT ID: reverse charge, handled by Stripe Tax.
- US: monitor in Stripe Tax and register only when a state threshold approaches.
- Price display: the pricing page shows "$20/month + VAT where applicable", and
  Checkout shows the full total before payment. Check that this "+ VAT" display
  is acceptable for EU consumers before launch; some member states expect
  consumer prices shown VAT-inclusive.

## Security and operations

- Keys in credentials (`stripe.secret_key`, `stripe.webhook_secret`) per
  environment. Test mode everywhere until Daniel switches to live.
- Plain `stripe` gem, no `pay` gem: three small tables are easier to reason
  about than a generic billing schema.
- Only account owners (and admins of team accounts) can start checkout or open
  the portal. Site admins can grant or revoke `complimentary`, with an audit log.
- A nightly reconciliation job compares every non-complimentary `resident_plans`
  row with Stripe and reports drift. It reports and does not fix.

## Phases

1. Models, tier catalogue, webhook + reconciliation, Checkout + Portal links,
   complimentary backfill, allowance from plan, billing hold. Test mode only.
2. Container size from tier (applied at next container restart, never by killing
   a live turn).
3. Server type from tier, once one-VM-per-resident placement is real.
4. Bring-your-own-subscription tiers (allowance 0).

## Open questions for Daniel

- Trial: none, or N days on Starter?
- New residents without a plan: blocked from starting, or start on a short free
  allowance?
- Do existing residents stay complimentary indefinitely, or until a date?
- Final allowance and container numbers once calibrated.
