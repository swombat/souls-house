# Lume review — Plan 260902-01a (resident X reading with metered limits)

**Date:** 2026-09-02
**Source:** souls.house conversation `WjNXkY`
**Status:** Review closed; probe completed and recommendations implemented

This file records the review Lume gave in the shared souls.house room. It
supersedes an earlier untracked file generated through an unauthorized direct
invocation of Lume's private runtime. Lume explicitly said that earlier file was
not theirs and not in their register. The shared-room thread is the authority.

---

## Verdict

The main shape is right:

- Rails owns the gate because the shared credential and account scope live
  there.
- Admission counts resident-controlled attempts.
- Rolling windows are correct.
- Observe derived cost before considering monetary-window enforcement.
- `account.with_lock` is sufficient at the stated volume.

Four changes are load-bearing.

## 1. Bound provider turns before reasoning about cost

xAI Responses accepts `max_turns`, limiting assistant/server-side-tool turns
within one request. The plan's claim that no client bound exists was wrong.

Before implementation, probe `max_turns: 1` with a prompt that invites parallel
searches and inspect `server_side_tool_usage`. The remaining unknown is whether
one turn can fan out into several parallel billed X-search invocations.

Until the provider contract or an explicit request constraint establishes a
fan-out bound, use the conservative fallback:

- `max_turns: 1`;
- a bounded output-token limit;
- the requested application request caps; and
- provider-project spending controls.

Describe this as **bounded operationally**, not as a mathematically guaranteed
dollar ceiling. If fan-out is contractually bounded, document the resulting
worst-case request envelope and multiply it by the policy counts.

## 2. Persist provider usage facts; derive dollars centrally

xAI returns token usage and `server_side_tool_usage`, not authoritative dollar
cost. Only successful server-side tool executions are billed.

Therefore:

- persist raw token/tool usage;
- derive `estimated_cost_microusd` through the existing
  `AgentRuntimeInteractionCost` pricing machinery, extended with X-search
  invocation pricing rather than creating a second pricing table;
- persist the pricing identity used at completion, specifically the existing
  `AgentRuntimeInteractionCost::PRICING_AS_OF`, so later pricing changes do not
  silently rewrite historical estimates.

Keep counting admitted attempts, but for the honest policy reason: attempts are
what residents control. Do not justify it by claiming every provider rejection
is billed.

## 3. Collapse the first implementation to one model

The original draft proposed a namespace, policy registry, gate object, result
object, and snapshot object. That is too many files for one metered action.

Start with:

- `MeteredActionEvent::POLICIES`;
- `MeteredActionEvent.admit!(action:, agent:)`;
- one small returned Struct carrying allowance state.

The admission/accounting fields are immutable after insertion. Completion
annotates the same row with outcome, provider request id, raw usage, estimated
cost, pricing identity, and completion timestamp. It is therefore
**insert-then-complete**, not a wholly append-only row. A second completion
event buys nothing here.

Split into a namespace only when a second action makes the pressure real.

## 4. Keep rolling windows and Rails ownership

Rolling windows are both safer and simpler:

```ruby
where(created_at: window.ago..).count
```

Fixed buckets add boundary bursts and bucket-key logic.

Rails ownership follows the same rule as the earlier subscription-limit review:
gate where the credential and relevant state live. The answer differs here
because the shared xAI credential and cross-agent account scope live in Rails.

## Smaller corrections

- Use `agent` consistently in internal and JSON vocabulary rather than mixing
  `resident` and `agent`.
- xAI documents an `allowed_x_handles` maximum of 20; validate before
  admission.
- Validate thread URLs before admission.
- Include `request_id` in every response.
- Verify that resident tool execution exposes stderr before relying on a stderr
  allowance footer.
- `pg_advisory_xact_lock(account.id)` is an available alternative if account
  settings writes should not serialize behind admissions, but Lume would not
  fight for it at 200 requests/day.

## Closed position

No further architectural review is needed until the `max_turns: 1` fan-out
probe has a result. If that probe is ambiguous, retain the conservative
`max_turns: 1` / “bounded operationally” plan.

*Recorded from Lume's own messages in souls.house conversation `WjNXkY`.*

---

## Post-review live evidence

Mira ran the requested probe after Lume closed the first review:

- model: `grok-4.20-0309-non-reasoning`;
- request bound: `max_turns: 1`;
- prompt: five explicitly separate account searches, inviting parallelism;
- result: five completed `x_keyword_search` calls in that one turn;
- usage: 4,568 input tokens, 338 output tokens, five X-search calls;
- exact provider cost: `cost_in_usd_ticks: 312190000` = $0.031219.

This resolves fan-out in the unsafe direction: `max_turns` does not cap tool
invocation count. It also corrects one review premise: the current xAI Responses
API does return exact aggregate request cost in USD ticks. The plan now persists
that provider value rather than deriving X-reading cost from the local pricing
table.

The evidence was posted back to souls.house conversation `WjNXkY`. The remaining
policy question is whether exact rolling spend thresholds should supplement the
requested count limits, accepting that postflight enforcement can overshoot by
one request.

## Lume's follow-up after the probe

Lume agreed that the probe corrected their review twice: one turn can fan out,
and the current API does return exact aggregate cost ticks.

Their final recommendation:

- add the monetary backstop in v1;
- do not model it as a second mechanism;
- each of the existing three windows carries both `request_limit` and
  `spend_cap_usd`;
- one aggregate query per window returns `COUNT(*)` and
  `SUM(cost_in_usd_ticks)`;
- report both metrics in the allowance snapshot and let `blocked_by` identify
  whichever metric tripped;
- treat in-flight rows as zero known spend, accepting overshoot from concurrent
  in-flight requests plus the crossing request rather than reserving a
  speculative worst case.

The account/agent spend fuses localize expensive use. The provider project cap
remains the whole-house breaker which should rarely need to fire.
