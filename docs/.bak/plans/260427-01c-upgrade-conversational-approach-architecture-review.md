# Upgrade Conversational Approach Architecture Review

**Date**: 2026-04-27
**Requirements**: `/docs/requirements/260427-01-upgrade-conversational-approach.md`
**Plan Reviewed**: `/docs/plans/260427-01c-upgrade-conversational-approach.md`
**Supporting Context**: `/docs/plans/260427-01b-upgrade-conversational-approach-dhh-feedback.md`

---

## Overall Assessment

Revision c is directionally strong and mostly faithful to the requirements. It clearly consolidates assistant-turn persistence, introduces provider-specific replay rules, and keeps RubyLLM behind an app-owned conversation contract.

The remaining architectural drift is concentrated in three areas:

- `context_tokens` is defined as the most recent assistant turn's provider-reported `input_tokens`, which is broader than the requirement's "replayed transcript/context size" metric and can move with system-prompt or tool-schema changes.
- Gemini/tool-call continuity is only partially specified: persistence is defined, but replay behavior, degradation behavior, and skip-reason behavior when stored tool continuity is missing are not fully nailed down.
- Reasoning tokens are stored, but the plan does not make them available as a first-class chat-level metric even though the requirements call for reasoning usage to remain separately available.

## Requirements Coverage

| Requirement | Status | Notes |
|-------------|--------|-------|
| 1. Single authoritative persistence contract for assistant turns | Covered | `Message#record_provider_response!` plus the shared streaming finalization path gives the plan one owner for assistant-turn persistence across jobs. |
| 2. Store replay metadata separately from display text | Covered | `replay_payload` cleanly separates replay-oriented metadata from `thinking_text`. |
| 3. Persist tool-call continuity metadata | Partially covered | The plan persists `tool_calls` rows and adds `tool_calls.replay_payload`, but it does not fully specify how Gemini continuity is replayed back out or what happens when required tool continuity is missing. |
| 4. Make thinking compatibility provider-specific | Covered | The global compatibility gate is removed and replaced with provider branches on replay. |
| 5. Never treat other agents' messages as same-agent reasoning replay | Covered | Other agents are replayed as ordinary conversation content via user-shaped content. |
| 6. Legacy fallback must be explicit and deterministic | Partially covered | Anthropic legacy fallback is explicit, but the plan does not define an equally explicit fallback for legacy or missing tool-call continuity metadata. |
| 7. Response jobs must use the same reasoning behavior | Covered | The plan routes all response paths through the same persistence and replay contract. |
| 8. Persist reasoning/cache token subfields correctly | Covered | `thinking_tokens`, `cached_tokens`, and `cache_creation_tokens` are preserved when surfaced by the provider. |
| 9. Replace `total_tokens` with separate context, lifetime, and reasoning metrics | Partially covered | `context_tokens` and `cost_tokens` are defined, but no chat-level reasoning metric is exposed. |
| 10. Token warnings must use the correct metric | Partially covered | Warnings move off lifetime totals, but they now depend on a prompt-size proxy rather than a transcript-focused context metric. |
| 11. Token accounting must reflect replayed reasoning honestly | Partially covered | The plan avoids lifetime-billing inflation, but `input_tokens` also includes non-transcript overhead such as system prompt and tools. |
| 12. Chat header copy must be updated | Covered | The header moves to `Context` and `Cost` labeling. |
| 13. Record why reasoning was disabled or degraded | Partially covered | `legacy_no_signature`, `provider_unsupported`, and `anthropic_key_unavailable` are handled, but missing tool-continuity degradation is not given a dedicated machine-readable reason. |
| 14. RubyLLM remains the provider adapter for this phase | Covered | The plan keeps RubyLLM in the adapter role and moves ownership of storage/replay into the app. |
| 15. Future RubyLLM replacement should become unnecessary through clear boundaries | Covered | The provider-adapter boundary is explicit and app-owned replay semantics are separated. |
| Migration and legacy-data handling requirements | Covered | No signature backfill is attempted; forward correctness is the focus. |
| Testing and direct-provider verification requirements | Partially covered | Positive-path coverage is strong, but the required regression case for tool use without persisted tool-call continuity metadata is not clearly present. |
| Acceptance criteria coverage | Partially covered | Most criteria are mapped, but criteria 4, 5, and 8 still depend on the unresolved tool-continuity and reasoning-metric gaps. |

## Drift Analysis

The largest unintentional drift is the definition of `context_tokens`. The requirements describe a conversation/transcript-size metric that should drive "long conversation" warnings. Revision c instead uses the latest assistant turn's `input_tokens`, which measures the full provider prompt seen on that turn. That count will include system-prompt and tool-schema overhead in addition to replayed transcript content, so the user-facing "Context" label stops meaning "how large this conversation is" and starts meaning "how large the provider prompt was on the latest turn."

There is also an intentional drift from the clarification that proposed a new `provider_model_id` scalar column. Revision c keeps `model_id_string` as the source of truth instead. That tradeoff appears deliberate and is supported by the previous DHH feedback, but it should still be treated as a conscious deviation from the written clarification rather than silent equivalence.

## Scope Creep

Scope creep is limited, but two additions are outside the original requirement set:

- Extending `fork_with_title!` to copy replay metadata and tool-call continuity into forked chats. This is sensible, but the requirements never explicitly ask for fork continuity.
- Persisting a stub assistant message for `anthropic_key_unavailable`. This supports diagnosability and UI consistency, but it is still additional behavior beyond the original requirements.

## Risks and Concerns

- The `context_tokens` proxy may make warning thresholds fluctuate with provider routing, system-prompt changes, or tool-definition changes even when the replayed conversation itself barely changed.
- Gemini continuity is under-specified at the exact point where the requirements are strictest: the plan shows how continuity metadata is stored, but not the complete replay payload shape or deterministic degradation path when that metadata is absent.
- Without a standalone chat-level reasoning metric, the plan weakens the requirement to keep reasoning usage separately available and makes acceptance criterion 8 harder to verify end to end.
- Relying on `model_id_string` instead of an explicit `provider_model_id` is probably acceptable, but only if implementation tests prove it always captures the exact resolved provider model identifier across direct-provider and routed-provider paths.

## Suggested Changes

1. Redefine `context_tokens` so it tracks replayed transcript/context size rather than full last-turn provider prompt size, or explicitly split those into separate metrics and keep warnings on the transcript metric.
2. Specify Gemini tool-call replay end to end: how stored `tool_calls.replay_payload` is serialized back into provider replay, what deterministic fallback is used when continuity metadata is missing, and which `reasoning_skip_reason` is recorded in that case.
3. Add an explicit chat-level reasoning-usage metric or clearly document where that metric lives if it is intentionally excluded from the main chat header.
4. If `provider_model_id` remains omitted, add a concrete implementation check proving `model_id_string` always satisfies the requirement for storing the exact provider model identifier used on the response.
5. Add the missing regression test for "tool use without persisted tool-call continuity metadata" so the hardest legacy edge case is covered by the plan before implementation starts.

## Verdict

Revision c is close, but it is not yet a fully faithful translation of the requirements. It should be revised once more to tighten the context-token definition, fully specify Gemini/tool-call degradation behavior, and make reasoning usage available as its own metric.
