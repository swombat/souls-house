# Plan 260902-01a — Resident X reading with metered limits

**Date:** 2026-09-02
**Status:** Implemented on 2026-09-02 after Lume review and live fan-out probe
**Review:** `260902-01b-resident-x-reading-metering-review-from-lume.md`
**Requested limits:**

- 10 admitted X-reading requests per rolling hour per resident
- 50 admitted X-reading requests per rolling 24 hours per resident
- 200 admitted X-reading requests per rolling 24 hours per account

Each window also carries an exact rolling spend cap matching the requested
dollar figure. xAI bills model tokens plus each successful server-side tool
invocation. A live probe on 2026-09-02 proved that
`max_turns: 1` still permits parallel fan-out: one turn executed five completed
`x_keyword_search` calls. That request cost $0.031219. Earlier probes cost
$0.029438 and $0.02661555. One HTTP request is therefore not a fixed
three-cent unit, and `max_turns` is not a hard tool-call cap.

---

## Goal

Give every hosted resident a narrow `soulshouse-x` helper that can inspect X
through souls.house's server-side xAI API credential, while:

1. preventing one resident from consuming an unbounded shared budget;
2. protecting the account-level shared pool when several residents call at
   once;
3. telling the resident what remains in every applicable window after every
   accepted or rejected call;
4. leaving behind an auditable usage/cost record; and
5. creating a small reusable metering seam for later paid shared tools without
   turning this into a billing platform.

This is a read-only capability. It does not use or change the existing
account-owned X OAuth integration used for posting.

---

## Existing seams

- Agent-scoped API keys already identify both `current_api_agent` and
  `current_api_account`.
- Production uses Solid Cache, and Rails' controller `rate_limit` DSL is
  already used by `YoutubeReadsController`.
- That controller limiter is sufficient for coarse abuse protection, but it is
  not the right source of truth here: we need three simultaneous windows,
  remaining counts, account-wide coordination, audit history, and provider cost
  recording.
- PostgreSQL is already the primary production database.
- The hosted runtime already ships small Python helpers which call agent-only
  API endpoints with `SOULSHOUSE_BEARER_TOKEN`.

---

## Architectural decision

**Meter admission in Rails, immediately before the shared paid provider call,
using an insert-then-complete database event and one account-row lock.**

The credential, authenticated resident/account identity, provider request, and
shared-account limit all meet in Rails. The runtime helper must not keep the
authoritative counter: containers can be replaced, multiple residents share an
account budget, and a client-side counter is bypassable.

Do not build this on the controller `rate_limit` DSL. Keep that DSL for simple
single-window traffic throttles; use the metering seam below for paid,
multi-scope actions.

### Why an account-row lock

`MeteredActionEvent.admit!` runs a short transaction under
`agent.account.with_lock`:

1. count admitted events in each applicable rolling window;
2. deny if any limit is exhausted;
3. otherwise insert one admitted event; and
4. return the post-insert allowance snapshot.

Every contender for either the agent or account X-reading pool therefore
serializes on the same existing account row. The external xAI call happens
**after commit**, never while holding the lock. At the requested maximum of 200
calls per account per day this simple lock is preferable to Redis scripts or
eventually-consistent counters. If admission ever causes meaningful contention
with unrelated account writes, `pg_advisory_xact_lock(account.id)` is a small
available substitution, not a framework required now.

---

## Minimal reusable framework

### 1. `metered_action_events` table

Suggested columns:

| Column | Purpose |
|---|---|
| `account_id` | Required account scope and lock owner |
| `agent_id` | Required agent scope |
| `action` | Stable vocabulary, initially `x_read` |
| `request_id` | UUID for correlation; unique |
| `outcome` | `admitted`, then `completed` or `upstream_error` |
| `provider` | Initially `xai` |
| `provider_request_id` | Optional upstream correlation id |
| `cost_in_usd_ticks` | Exact aggregate provider-reported cost in 1e-10 USD ticks |
| `usage` | JSONB with raw provider token and `server_side_tool_usage` facts, never credentials or source content |
| `outcome_recorded_at` | Completion annotation time |
| timestamps | Admission and later row update |

Indexes:

- `(action, agent_id, created_at)`
- `(action, account_id, created_at)`
- unique `(request_id)`

Quota counting includes every **admitted** event regardless of final outcome.
The quota is intentionally on attempts because attempts are what an agent
controls. xAI reports only successful server-side tool executions as billable,
so do not justify attempt-counting by claiming every provider rejection costs
money. Invalid input and missing local configuration are rejected before
admission and do not consume allowance.

Retention can initially be ordinary application retention. A later cleanup job
may delete events older than the longest audit horizon, but no cleanup is needed
for correctness.

### 2. Policy and admission on one model

Keep limits reviewable and version-controlled rather than editable database
configuration:

```ruby
MeteredActionEvent::POLICIES = {
  "x_read" => [
    {
      id: "agent_hour", scope: :agent, window: 1.hour,
      request_limit: 10, spend_cap_usd: "0.30"
    },
    {
      id: "agent_day", scope: :agent, window: 24.hours,
      request_limit: 50, spend_cap_usd: "1.50"
    },
    {
      id: "account_day", scope: :account, window: 24.hours,
      request_limit: 200, spend_cap_usd: "6.00"
    }
  ]
}.freeze
```

The USD strings are presentation-friendly policy constants, but enforcement
converts them once to integer USD ticks (`1 tick = 1e-10 USD`) and compares
integers. Never use binary floats for the spend gate.

Use rolling windows, not clock-hour/UTC-day buckets. Fixed boundaries permit 20
agent calls across an hour boundary or 100 across midnight within minutes,
which conflicts with the cost-containment purpose.

Do not introduce database-editable plans, per-account overrides, purchased
credits, or a general pricing catalogue in this iteration.

Public shape:

```ruby
result = MeteredActionEvent.admit!(
  action: "x_read",
  agent: current_api_agent
)
```

Keep the first implementation to this model plus one small returned Struct. Do
not create a `MeteredAction` namespace, separate gate service, result class, and
snapshot class before a second action creates real pressure to split them.

For each window, one indexed query loads the admitted rows still inside it,
ordered oldest first, selecting only `created_at` and `cost_in_usd_ticks`.
At these policy maxima that is at most 200 rows. Ruby then calculates:

- admitted request count;
- `SUM(cost_in_usd_ticks)`, treating in-flight `NULL` as zero; and
- the exact earliest expiry point at which both count and spend permit another
  admission.

The returned Struct contains:

- `allowed?`
- `request_counted?`
- all request and spend window snapshots;
- `blocked_by` limit ids when denied; and
- `retry_after` / next slot time when denied.

Each window snapshot contains:

```json
{
  "id": "agent_hour",
  "scope": "agent",
  "window_seconds": 3600,
  "requests": {
    "limit": 10,
    "used": 3,
    "remaining": 7
  },
  "spend": {
    "cap_usd": "0.30",
    "used_usd": "0.09",
    "remaining_usd": "0.21"
  },
  "next_slot_at": "2026-09-02T18:41:22Z"
}
```

`next_slot_at` means the earliest event-expiry point at which this window would
permit another admission. For a request-count block that is often the oldest
event plus the window; for a spend block, several old events may need to expire
before the accumulated spend falls below the cap. This avoids a misleading
`Retry-After`.

Denied attempts do not create events and do not reduce remaining allowance.
`blocked_by` identifies the exact metric, for example
`agent_hour.requests`, `agent_hour.spend`, or both.

In-flight admitted rows have no cost yet and count as zero spend. Do not reserve
a speculative worst-case amount at admission. A spend cap can therefore
overshoot by the cost of unresolved concurrent in-flight requests plus the
request which crosses the threshold. This is accepted; the xAI project cap is
the final whole-house breaker.

### 3. Event completion

After the provider call, annotate the admitted event with outcome, provider
request id, raw token/tool usage, `outcome_recorded_at`, and the provider's exact
`cost_in_usd_ticks`.

xAI's current Responses API returns exact aggregate request cost in
`usage.cost_in_usd_ticks`, covering tokens and server-side tool invocations.
Persist that provider fact directly. Do not route this value through
`AgentRuntimeInteractionCost`; that service remains appropriate for interactions
whose dollar cost must be estimated from token usage.

This update is observational, not part of admission correctness. If it fails,
the request remains conservatively counted as admitted.

---

## X-reading endpoint and provider call

Add:

- `POST /api/v1/x_reads`
- `Api::V1::XReadsController`
- `XReader`
- runtime helper `agent-runtime/soulshouse-x`

The endpoint is agent-key-only, like YouTube reading.

### Initial operations

Keep the public surface smaller than the provider:

1. `search QUERY`
   - optional repeated `--handle` filters, capped at the documented
     `allowed_x_handles` maximum of 20;
   - optional `--from YYYY-MM-DD` and `--to YYYY-MM-DD`;
   - returns a grounded answer plus provider citations.
2. `thread X_URL [QUESTION]`
   - validates a recognizable X post URL before admission;
   - reads one post/thread and answers an optional question.

No posting, following, liking, DMs, arbitrary provider tool selection, web
search, image understanding, or video understanding in this iteration.

### Request shaping

- Use the non-reasoning Grok model verified during implementation, unless a
  cheaper current model proves equally reliable.
- Offer only `x_search`; do not offer `web_search`.
- Keep image/video understanding disabled.
- Set `max_turns: 1`. The live probe established that one turn can still fan out
  into several parallel searches, so a higher value only increases exposure.
- Set a bounded output-token limit.
- Put strict untrusted-content instructions around retrieved posts.
- Ask for post ids, author handles, timestamps, concise paraphrases, and
  citations. Prefer canonical `https://x.com/i/status/<id>` URLs constructed by
  souls.house when a post id is available rather than trusting model-authored
  handle paths.
- Expose raw provider token usage, `server_side_tool_usage_details`, and exact
  provider-reported cost in JSON diagnostics.

xAI documents `max_turns`, which bounds assistant/server-side-tool turns inside
one Responses request, while allowing several tools to run in parallel during a
turn. The live probe deliberately requested five separate account searches and
returned five completed `x_keyword_search` calls with `max_turns: 1`.

The v1 safety claim is therefore **bounded operationally**, not mathematically
guaranteed:
`max_turns: 1`, bounded output, the request-count policies, and provider-project
spending controls.

Implemented defense in depth:

1. the application request limits in this plan;
2. `max_turns` plus narrow request shaping and output bounds;
3. persist raw provider usage and exact provider-reported cost;
4. require an xAI-console project spending alert/hard cap if xAI offers the
   required control; and
5. exact rolling monetary-window enforcement from provider-reported aggregate
   request cost.

The application caps are exact against completed cost already known at
admission time. A crossing request and unresolved in-flight requests can still
overshoot because their exact cost is only available after completion.

---

## Response contract

Every success includes:

```json
{
  "request_id": "4af2ec6b-...",
  "content": "...",
  "citations": [],
  "model": "...",
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "server_side_tool_usage": {
      "SERVER_SIDE_TOOL_X_SEARCH": 1
    },
    "cost_in_usd_ticks": 294380000,
    "cost_usd": "0.029438"
  },
  "rate_limits": {
    "action": "x_read",
    "request_counted": true,
    "windows": [
      {
        "id": "agent_hour",
        "scope": "agent",
        "requests": {
          "limit": 10,
          "used": 3,
          "remaining": 7
        },
        "spend": {
          "cap_usd": "0.30",
          "used_usd": "0.09",
          "remaining_usd": "0.21"
        },
        "next_slot_at": "2026-09-02T18:41:22Z"
      },
      {
        "id": "agent_day",
        "scope": "agent",
        "requests": {
          "limit": 50,
          "used": 12,
          "remaining": 38
        },
        "spend": {
          "cap_usd": "1.50",
          "used_usd": "0.35",
          "remaining_usd": "1.15"
        },
        "next_slot_at": "2026-09-03T08:04:10Z"
      },
      {
        "id": "account_day",
        "scope": "account",
        "requests": {
          "limit": 200,
          "used": 41,
          "remaining": 159
        },
        "spend": {
          "cap_usd": "6.00",
          "used_usd": "1.18",
          "remaining_usd": "4.82"
        },
        "next_slot_at": "2026-09-03T07:58:02Z"
      }
    ]
  }
}
```

Every limit denial returns HTTP 429 with:

- the same `rate_limits` structure;
- `request_counted: false`;
- `blocked_by`;
- a concise error;
- `Retry-After` set to the latest next-slot time among the blocking windows.

Configuration, validation, and upstream errors should also include the
allowance snapshot whenever admission occurred, so the resident never has to
guess whether an attempted request consumed a slot.

### Helper presentation

Normal output prints the answer to stdout and a compact allowance footer to
stderr so redirection/piping of the answer stays clean:

```text
[X allowance: agent 7/10 · $0.09/$0.30 hour, 38/50 · $0.35/$1.50 day;
account 159/200 · $1.18/$6.00 day]
```

`--json` prints the complete response. On HTTP 429 the helper prints the
blocking windows and next-slot time explicitly. Verify with a real hosted agent
that Chaos surfaces helper stderr; if it does not, print the allowance footer to
stdout after the answer instead.

---

## Failure and concurrency semantics

- **Concurrent agents:** serialized by the account row; the 201st account
  admission cannot slip through.
- **Concurrent calls by one agent:** covered by the same account lock and agent
  count query.
- **Invalid request:** reject before admission; no slot consumed.
- **Provider timeout/network ambiguity:** slot remains consumed because the
  quota governs admitted agent-controlled attempts, independent of whether
  provider billing can later be proven.
- **Provider rejection:** slot remains consumed for the same attempt-policy
  reason. Raw usage should show zero successful X-search executions when none
  were billed.
- **Spend cap reached:** subsequent admissions are denied even when request
  count remains. This localizes an expensive agent instead of waiting for the
  whole-house xAI project breaker.
- **Concurrent in-flight spend:** unresolved rows count as zero spend, so a cap
  can overshoot by concurrent in-flight cost plus the crossing request. Do not
  hold the account lock during provider I/O to prevent this.
- **Database unavailable:** fail closed before contacting xAI. A metered paid
  tool should not bypass its budget gate because accounting is unavailable.
- **Event completion update fails:** response may still succeed; event remains
  admitted and counted, with an error logged for reconciliation.
- **Cache flush/deploy/container replacement:** no effect on limits.

---

## Observability

Initial observability should be deliberately small:

- structured logs with request id, account id, agent id, outcome, raw
  server-side tool count, exact cost ticks, and normalized USD cost;
- Rails console/queryable event rows;
- Honeybadger notification if event completion repeatedly fails;
- no new customer/admin UI in this iteration.

A later account usage view can be built from the same events if actual use
justifies it.

Never store the resident query, returned posts, model answer, API credential, or
raw provider response in the metering table.

---

## Implementation sequence

The provider probe is complete: `max_turns: 1` permitted five parallel
X-searches, and the response returned exact aggregate `cost_in_usd_ticks`.

1. Add `metered_action_events`, `MeteredActionEvent::POLICIES`,
   `MeteredActionEvent.admit!`, indexes, and one returned Struct.
2. Enforce request count and exact recorded spend through the same three
   rolling-window aggregate queries under the account lock.
3. Persist raw token/tool usage, exact provider `cost_in_usd_ticks`, and a
   normalized USD value on completion.
4. Test rolling request windows, account/agent interaction,
   denied-attempt semantics,
   exact remaining counts, next-slot times, and concurrent admission.
5. Build and unit-test `XReader` with injected transport; normalize citations,
   raw usage, server-side tool counts, exact cost ticks, normalized cost, and
   upstream errors.
6. Add the controller and integration tests, including all success/error
   allowance responses and 429 `Retry-After`.
7. Add `soulshouse-x`, runtime documentation, Dockerfile wiring, and helper
   tests.
8. Run focused tests/lint, then the full project suites and report unrelated
   baseline failures separately.
9. Deploy the Rails app and runtime image.
10. Reconcile hosted agent containers to the new image.
11. Run live production tests for success, remaining-count decrement, agent
    hourly denial, account coordination with controlled fixture limits, stderr
    visibility, and absence of credential/source-content logging.

---

## Tests that carry the design

- The 10th resident-hour call is admitted; the 11th is denied.
- A denied call does not consume another slot.
- A resident with hourly room but 50 rolling-day events is denied.
- Two residents with individual room cannot exceed 200 account-day admissions.
- An agent with request room but $0.30 rolling-hour spend is denied.
- An account with request room but $6 rolling-day spend is denied.
- `blocked_by` distinguishes request and spend exhaustion.
- In-flight rows count toward request limits but as zero recorded spend.
- Completion cost can cross a spend cap; the next admission is denied.
- Concurrent calls at a one-slot boundary admit exactly one.
- Rolling windows release one slot when the oldest event ages out.
- The post-admission snapshot includes the newly consumed request.
- Invalid input does not create an event.
- Timeout and upstream rejection retain the admitted event.
- `max_turns: 1` is sent to xAI, and the provider probe records any per-turn
  tool fan-out.
- Raw `server_side_tool_usage_details` and exact `cost_in_usd_ticks` are
  persisted.
- Normalized USD cost is derived directly from the immutable provider ticks,
  not from a mutable local pricing table.
- Success, upstream error, and 429 all expose the appropriate allowance
  snapshot.
- Every response exposes `request_id`.
- A user-scoped API key cannot call the endpoint.
- Metering records contain no query, source text, answer, or credential.

---

## Non-goals

- Exact provider invoice reconciliation
- General subscription/billing plans
- User-purchased credits
- Per-account custom limits
- A Redis dependency
- Runtime-local authoritative counters
- Replacing simple controller rate limits everywhere
- Write access to X
- Using residents' Grok OAuth tokens
- Treating the application spend cap as an absolute no-overshoot guarantee

---

## Review decisions

Lume's shared-room review resolved most of the architecture:

1. One `MeteredActionEvent` model owns policy and admission until a second
   action creates pressure to split it.
2. Completion annotates the admission row; no second event.
3. Rolling windows remain.
4. The initial recommendation was not to build monetary-window enforcement in
   v1, based on the expectation that per-request tool execution could be
   bounded and cost would need local estimation.
5. Rails owns the gate because the shared credential and account policy live
   there.

The live probe subsequently resolved the provider question:

> With `max_turns: 1`, xAI executed five completed billed X-search invocations
> in parallel during one turn.

The response also returned exact `cost_in_usd_ticks`, rather than requiring a
local estimate. Lume's follow-up resolved the reopened decision:

- add the spend caps now;
- model them as a second aggregate on the same three policy windows, not as a
  separate limiting framework;
- report both count and spend in every snapshot;
- accept postflight/concurrent overshoot rather than reserving speculative
  worst-case cost; and
- retain the xAI project cap as the whole-house breaker.
