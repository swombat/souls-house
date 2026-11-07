# Existing-resident Checkout attempts (#629)

Status: contract reviewed by Lume (YAqWkY/jlXXmo); implementation review pending.
Authority: Daniel's jaMopj/JNwwvZ; build/config split YZxAnj/emmmWE.

## Boundary

An owner may buy a configured, eligible offer for an existing hosted resident
without a live subscription. At cost has no house-model allowance: choose an
own-funded model first. Buying changes neither VM size nor location. Opening
Checkout grants nothing; the existing validated subscription sync applies payment.
Existing paid subscriptions still use the same-rate PlanChange path.

## Durable intent and serialization

`BillingCheckoutAttempt` records resident, account, tier, rate, grant, price,
unique UUID-based Stripe key and the complete JSON create payload, plus the
remote session id once learned and a resolved timestamp. Intent is committed
before any create call. No session secrets or card details are stored.

Checkout holds a **session** advisory lock using SubscriptionSync's existing
namespace/resident pair, on one checked-out database connection, across intent,
remote calls and publication. Short write transactions commit under that lock.
It refuses an enclosing database transaction: a savepoint cannot provide a
durable pin. Competing Checkout requests fail fast with a retry message.
Unlock is uncached and in ensure; uncertain acquisition or release discards the
database connection. Process death releases the connection/lock.
SubscriptionSync's transaction lock conflicts with this lock, with no reverse
row/advisory acquisition order. Webhooks may fetch before waiting, but refetch
under their lock as today.

Before creating an attempt, settle every unresolved attempt for this resident:

- Unknown id: replay its **stored** payload/key, never recompute grant, price,
  URLs, name or customer. Persist the returned id before doing anything else.
- An unknown attempt more than 23 hours old is not replayed: Stripe can prune
  idempotency keys after 24 hours. It blocks for operator reconciliation.
- Refused replay, timeout, failed local save, unreadable state or failed expiry
  remain unresolved and block replacement. No abandonment/new-key escape hatch.
- Same offer and open session: return its existing URL. A different offer
  requires confirmed expiry before pinning its replacement.
- Complete session: block until its subscription is recorded and ended.
  Paid-but-not-yet-synced blocks in either webhook order.
- Expired, or complete with a recorded ended subscription: mark resolved.
  A subsequent attempt has its own new identity.

For pre-migration sessions, reconcile the entitlement's existing session pointer
and paginate the customer's Checkout sessions, scoped by client_reference_id to
this resident, before its first durable attempt. This catches accepted creates
whose old code lost the local answer. An empty listing is not evidence about a
new unresolved attempt. The rolling container swap briefly allows old standard
Checkout workers using the row-lock-only protocol: an acknowledged legacy risk,
not a new at-cost path (old code refuses at cost).

## Validation and recovery

Fresh pins require a current account grant; recovering an authorised attempt
keeps its original grant even if withdrawn. A retired but recognised price
remains bound to its original offer. Customer, resident and subscription ownership
validation in SubscriptionSync is unchanged. No entitlement or allowance is
changed by Checkout itself.

Operator recovery of an old/refused unknown intent requires establishing its
remote session and recording that id on the attempt, then letting ordinary
retrieval/expiry/payment checks settle it. Never delete the attempt or clear its
block merely because a search found nothing. This PR adds no automatic sweeper,
Stripe charge, rate change for a paid resident or infrastructure operation.

The operator command is `bin/rails billing:checkout:reconcile`, with environment
arguments `ATTEMPT_ID`, `SESSION_ID`, `OPERATOR` and `REASON`. It verifies the
session's customer, resident and complete attempt metadata, binds its id and
writes a `billing_checkout_reconciled` audit row. It does not resolve the
attempt, charge, or apply an entitlement. The owner's next Checkout runs the
ordinary state/expiry checks. If no matching session can be established, the
attempt stays blocked; automatic "never created" recovery is deferred.

All billing SDK clients inherit explicit public Stripe timeout settings: 3s
open, 8s read, 8s write, no network retries. Checkout checks a 30s cooperative
operation budget between calls (including listing pages). These are network
timeouts, not a strict whole-operation wall-clock guarantee: a slow trickling
response can extend a read. No asynchronous Ruby interruption surrounds database
writes. A deadline ends the request, not its durable attempt.

## Tests

Use fake Stripe cached responses with parameter equality, before/after-acceptance
faults and real PostgreSQL connections for committed intent and contention.
Cover crash before create, after acceptance before id publication, grant/price/
URL drift, both webhook orders, competing offers with a paused create, refused
replay, stale unknown intent, failed expiry, complete/expired sessions, legacy
pointer/list pagination, owner/account isolation and zero at-cost allowance.
All test destinations and credentials are synthetic.
