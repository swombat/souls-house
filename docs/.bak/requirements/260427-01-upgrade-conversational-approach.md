# Upgrade Conversational Approach

## Summary

Upgrade conversation handling so multi-turn, multi-agent chats behave consistently across providers, especially for thinking/reasoning models.

The current system mixes:

- RubyLLM as the provider adapter
- custom Rails persistence for streamed multi-agent responses
- a single provider-agnostic "thinking compatibility" rule
- a chat token counter that is actually cumulative billing, not current conversation size

The result is that thinking works on the first turn, then often drops on the second turn, especially for Anthropic. It also makes conversation token counts look much larger and more alarming than the real active context.

This upgrade must:

1. preserve the provider metadata needed to continue reasoning-enabled conversations safely
2. make replay rules provider-specific instead of Anthropic-shaped for everyone
3. keep hidden reasoning usage separate from visible conversation length
4. make token displays honest about what they mean
5. reduce framework confusion by giving the app a single explicit contract for conversation persistence and replay

## Context

### What was observed

From investigation on April 27, 2026:

- The multi-agent/manual response path persists `thinking_text`, but does not persist `thinking_signature`, `thinking_tokens`, cached token fields, or tool-call replay metadata.
- The app then decides whether thinking is allowed by checking whether prior assistant turns from the same agent have both thinking text and a signature.
- In the production-copy development database, there were hundreds of assistant messages with thinking text and zero with stored thinking signatures.
- This means any agent whose first turn stores visible thinking will almost always fail the compatibility check on the next turn and have thinking disabled.
- The chat header currently displays total lifetime billed tokens as if it were current conversation size.

### Why this is happening

RubyLLM already exposes the metadata needed for provider-specific reasoning continuity:

- Anthropic returns thinking text plus a replay signature
- Gemini exposes thought signatures, including tool-call continuity data
- OpenRouter/OpenAI-style responses can expose reasoning text, reasoning signatures, and reasoning token counts

But the app's custom streaming persistence path stores only a reduced subset of that response.

### Architectural diagnosis

The problem is not primarily that RubyLLM cannot support this.

The problem is that the app is currently halfway between two designs:

1. RubyLLM-managed conversation persistence
2. app-managed custom conversation persistence

The multi-agent path uses RubyLLM for transport and chunk normalization, but bypasses RubyLLM's richer persistence model. That means provider-specific reasoning state is lost before the next turn.

## Product Goals

### 1. Reasoning continuity must be deterministic

If a provider requires replay metadata to continue a reasoning-enabled conversation, that metadata must be persisted and replayed correctly.

### 2. Thinking must not silently drop for the wrong reasons

Anthropic's replay rules must not be applied to OpenAI, Gemini, xAI, or OpenRouter models unless they truly require equivalent continuity artifacts.

### 3. Conversation length and token spend must be separated

Users should be able to tell the difference between:

- how large the active replayed conversation is
- how much total token usage has been billed over the life of the chat

### 4. The app must own its conversation contract

The application should use RubyLLM as a provider adapter, but the app itself must define and persist the data required for:

- rendering messages
- replaying messages to providers
- reasoning continuity
- token accounting

### 5. Legacy conversations must degrade explicitly

Old messages that do not have replayable reasoning metadata must not cause confusing silent behavior. The system must choose a clear, tested fallback.

## Non-Goals

- Replacing RubyLLM wholesale in this project phase
- Changing agent memory, summaries, or whiteboard behavior
- Redesigning the chat UI beyond token labeling and any small reasoning-state indicators needed for clarity
- Exposing raw encrypted provider signatures to normal users

## Requirements

### 1. Introduce a single authoritative persistence contract for assistant turns

All assistant responses, whether produced by:

- `AiResponseJob`
- `ManualAgentResponseJob`
- `AllAgentsResponseJob`
- tool-call follow-up rounds

must persist through one shared response-persistence contract.

That contract must preserve, when available:

- final assistant content
- visible thinking text
- provider replay signature or equivalent continuity artifact
- reasoning/thinking token counts
- prompt/input tokens
- completion/output tokens
- cached input tokens
- cache creation/write tokens
- exact provider model identifier used for the response
- tool-call metadata required for provider replay continuity

This must eliminate the current split where some paths use RubyLLM's richer persistence semantics and others flatten the response down to content plus token totals.

### 2. Store provider replay metadata separately from display text

The system must distinguish between:

- **display-oriented reasoning data**: text that can be shown in the UI
- **replay-oriented reasoning data**: exact signatures, encrypted reasoning details, or provider-specific payload fragments required for future turns

`thinking_text` alone is not a sufficient replay contract.

The system must persist enough structured data to support future provider replay rules without relying on re-deriving them from flattened UI fields.

This may be implemented via existing columns plus new structured metadata, but the end state must support:

- Anthropic signed thinking replay
- Gemini thought signature continuity, including tool-call continuity
- OpenRouter/OpenAI-style reasoning details where provided
- providers that expose encrypted reasoning artifacts instead of plain text

### 3. Persist tool-call continuity metadata

Provider-specific reasoning continuity for tool use must be preserved.

Requirements:

- tool calls made during assistant turns must be persisted as `tool_calls` rows rather than being represented only in `tools_used`
- tool-call metadata required for reasoning continuity must be stored
- Gemini thought signatures for function calls must be replayable on subsequent turns
- the app must not consider tool-use reasoning continuity "supported" unless the corresponding tool call records were actually persisted

`tools_used` may remain as a UI/audit convenience, but it is not enough to support provider replay semantics.

### 4. Make thinking compatibility provider-specific

The app must replace the current single compatibility rule with provider-specific reasoning continuity rules.

#### Anthropic

For Anthropic thinking models:

- replay must preserve the provider-required thinking block continuity for prior assistant turns from the same agent
- if tool use occurred, provider-required tool continuity artifacts must also be replayed
- absence of replayable continuity metadata must be treated as an Anthropic-specific compatibility problem, not as a generic "thinking unsupported" state

#### OpenAI / OpenRouter / xAI / Gemini

For other providers:

- the system must not disable thinking merely because a prior assistant turn lacks an Anthropic-style signature
- replay rules must match the real provider behavior
- if a provider allows a reasoning-enabled next turn without replaying hidden reasoning from prior turns, the system must allow that

### 5. Other agents' messages must never be treated as same-agent reasoning replay

In group conversations:

- only the current agent's own prior assistant turns may be considered candidates for same-agent reasoning replay
- other agents' prior messages must continue to be replayed as ordinary conversation content, not as provider-native reasoning blocks
- the presence or absence of another agent's reasoning metadata must not disable thinking for the current agent

### 6. Legacy conversation fallback must be explicit and test-backed

Existing conversations already contain assistant messages with visible thinking text but no replay signatures.

The system must not fabricate signatures.

For historical assistant turns that lack replayable reasoning metadata, the app must use an explicit fallback policy.

That fallback policy must satisfy all of the following:

- no silent mid-conversation thinking drop without a recorded reason
- no global/provider-agnostic disabling of thinking
- no invalid provider replay payloads
- deterministic behavior across retries and future turns

For Anthropic conversations, the fallback must be validated with direct provider tests. Acceptable end states include either:

- replaying the assistant message text without replaying historical thinking, if Anthropic accepts that
- or using a different deterministic continuity fallback for unreplayable legacy turns

The exact fallback may be chosen during implementation, but it must be explicit in code and covered by tests.

### 7. Response jobs must use the same reasoning behavior

Reasoning continuity must work the same way for:

- ordinary single-agent chats
- manual agent triggering
- all-agents response chains
- agent-only chats
- tool-call continuation rounds

There must not be one set of persistence/replay semantics for ordinary chats and another for multi-agent chats.

### 8. Persist reasoning token fields correctly

The app must store reasoning-specific usage separately from ordinary output.

At minimum, the persistence layer must support:

- `thinking_tokens` / `reasoning_tokens`
- `cached_tokens`
- `cache_creation_tokens` or equivalent cache-write usage

These values must be stored whenever the provider surfaces them.

If a provider does not expose a field, it may remain null, but the app must not silently discard surfaced values.

### 9. Replace the single `total_tokens` concept with separate token metrics

The app must stop using a single "total tokens" value to represent two different concepts.

It must expose at least these separate metrics:

#### A. Transcript context tokens

An estimate of the replayed conversation transcript size.

This should represent the visible conversation material that will be replayed into future turns, excluding:

- hidden/provider-private reasoning tokens that are not replayed
- lifetime billing accumulation from prior API calls
- cached token discounts/write metrics

This is the number that should drive "long conversation" warnings.

#### B. Lifetime billed usage tokens

An accumulated usage metric across the life of the chat, built from stored per-message usage:

- prompt/input tokens
- output tokens
- optionally reasoning tokens as a separately labeled sub-metric
- optionally cached/cache-write tokens as separately labeled sub-metrics

This number is useful for cost/usage reporting, but it must not be labeled as current conversation size.

#### C. Reasoning tokens

Reasoning usage must be available as its own metric when the provider exposes it.

These tokens must not be merged into "conversation length" unless the underlying reasoning artifact is actually replayed as part of the prompt context.

### 10. Token warnings must use the correct metric

The existing long-conversation warning thresholds must be applied to transcript context size, not lifetime billed usage.

The UI must clearly label what it is showing, for example:

- `Context: 18.4k tokens`
- `Lifetime usage: 132k tokens`

The precise wording may vary, but the distinction must be obvious.

### 11. Token accounting must reflect replayed reasoning honestly

If a provider requires replaying reasoning blocks into future context, the replayed reasoning text/signature payload may contribute to transcript context size.

If a provider does not replay hidden reasoning, those hidden reasoning tokens must not inflate the transcript-context metric.

This rule is essential so the token display tracks real prompt size rather than provider billing internals.

### 12. The chat header copy must be updated

The chat header and any related warning badge copy must stop presenting cumulative usage as if it were conversation length.

Minimum UI requirements:

- the primary token label must refer to transcript/context size, not raw lifetime usage
- if lifetime usage is shown, it must be secondary and explicitly labeled
- warning text such as "Long conversation" or "Very long" must be based on the context metric

### 13. The app must record why reasoning was disabled or degraded

When reasoning is not used for a turn even though the agent setting is enabled, the system must record a machine-readable reason.

Examples:

- provider does not support displayable reasoning
- missing replay signature for legacy Anthropic turn
- provider does not expose replayable reasoning details
- tool-call continuity metadata missing

This reason may be surfaced in debug/admin tooling first, but it must exist so the system is diagnosable.

### 14. RubyLLM remains the provider adapter for this phase

This upgrade does not require replacing RubyLLM.

For this phase, the app should continue to use RubyLLM for:

- provider request formatting
- streaming normalization
- model/provider routing support

But the app must stop relying on accidental or partial RubyLLM persistence behavior.

The application must explicitly own:

- what gets stored for each message
- what gets replayed for each provider
- what counts as context
- what counts as usage

### 15. Any future RubyLLM replacement must be made unnecessary by clear boundaries

If the app later chooses to replace RubyLLM, that should be a transport/provider swap, not a redesign of the conversation model.

This upgrade must leave the codebase with a clean boundary:

- provider adapter in one layer
- app-owned conversation/replay contract in another

## Migration and Data Requirements

### 1. Schema support

The message persistence model must support all required usage and replay fields.

If not already present, schema changes must be added for:

- cached input token counts
- cache creation/write token counts
- structured provider replay metadata for assistant messages
- any missing tool-call metadata required for provider continuity

### 2. Legacy data handling

No attempt should be made to backfill or invent missing provider signatures for old messages.

Instead:

- existing conversations must be classified as legacy where required
- the fallback rules in this document must be applied deterministically
- new messages created after this upgrade must persist complete metadata going forward

### 3. Forward correctness is mandatory

The system must guarantee that newly created conversations do not reproduce the current failure mode where:

- first turn stores visible thinking
- second turn loses thinking because replay metadata was not saved

## Testing Requirements

### 1. Unit tests

Add or update tests for:

- assistant response persistence saving signatures and token subfields
- tool-call persistence saving provider continuity metadata
- provider-specific compatibility rules
- token metric calculations

### 2. Integration tests

Add end-to-end tests for:

- Anthropic same-agent multi-turn conversation with thinking staying enabled across turns
- Anthropic conversation with another agent speaking first
- OpenAI/OpenRouter thinking models not being blocked by Anthropic-style signature checks
- Gemini tool-calling continuity across multiple turns
- token metric display and warning thresholds using context size rather than lifetime usage

### 3. Legacy regression tests

Add tests that simulate historical messages with:

- visible thinking text but no signature
- no reasoning metadata at all
- tool use without persisted tool-call continuity metadata

These tests must verify that the new behavior is explicit and deterministic.

### 4. Direct provider verification

At least the following provider behaviors must be verified with direct-provider tests or VCR-backed integration tests:

- Anthropic replay requirements for reasoning-enabled follow-up turns
- Gemini thought-signature continuity for tool calls
- OpenAI/OpenRouter behavior when reasoning is enabled but no replay signature exists

## Acceptance Criteria

This work is complete when all of the following are true:

1. A two-turn Anthropic thinking conversation created after the upgrade keeps thinking enabled on turn two, assuming the first turn used thinking successfully.
2. Multi-agent chats do not disable an agent's thinking because another agent lacks reasoning metadata.
3. New assistant messages persist reasoning signatures and reasoning token metadata whenever the provider returns them.
4. Tool calls are actually persisted when provider continuity depends on them.
5. Legacy conversations no longer fail through silent, unexplained reasoning drop.
6. The primary token label in the chat UI reflects active transcript/context size rather than cumulative billing.
7. Lifetime usage remains available separately for reporting/debugging.
8. Reasoning tokens are stored separately and do not inflate context warnings unless they are truly replayed.
9. The multi-agent/manual-response path and the ordinary chat path share the same persistence semantics for assistant responses.
10. RubyLLM can remain in place without being the source of ambiguity about what the app stores or replays.

## Implementation Guidance

### Recommended direction

The recommended approach is:

1. keep RubyLLM as the provider adapter
2. move all assistant-turn persistence through a single app-owned persistence layer
3. introduce an app-owned replay model for provider-specific reasoning continuity
4. split token accounting into context size vs lifetime usage

### What not to do

Do not:

- keep the current provider-agnostic compatibility gate
- treat `thinking_text` as a sufficient replay contract
- keep summing per-message billed prompt tokens and label the result as current conversation size
- rely on `tools_used` as if it were tool-call replay state
- replace RubyLLM first in order to avoid fixing the app's data contract

## Decision Record

For this upgrade, RubyLLM should **not** be replaced.

The correct fix is to make the app's conversational model explicit and provider-aware, while continuing to use RubyLLM as the adapter layer underneath.

## Clarifications

Captured during spec planning, 2026-04-27:

### 1. Legacy fallback policy is per-turn, not per-conversation

For Anthropic conversations, when a historical assistant turn lacks a replayable signature, the system MUST drop the thinking block from the API replay payload for that specific turn (replaying it as plain assistant text). It MUST NOT disable thinking on the current turn just because some historical turn lacks a signature.

This is rooted in Anthropic's actual replay rule: any thinking block that IS included must be valid, but turns without thinking blocks in the replay are accepted. This means a conversation can recover — once new turns post-upgrade are written with full signatures, those new turns carry valid thinking, and thinking continues working from then on. Only the visible thinking text from legacy turns is dropped from the *replay payload* (it remains visible in the UI).

The previous global rule (`thinking_compatible_for?` returning false if any historical turn lacks a signature) is incorrect and must be replaced.

### 2. Replay metadata storage uses a single jsonb column

A single `replay_payload jsonb` column on `messages` is the chosen container for provider-specific replay metadata (Anthropic signatures, Gemini thought signatures, OpenRouter reasoning_details, etc.). New scalar columns are added only for the missing token counters (`cached_tokens`, `cache_creation_tokens`, `provider_model_id`).

This avoids per-provider schema churn and keeps provider-shape variance contained in one structured field.

### 3. Token display uses Context and Cost (broken into input + output)

The chat header surfaces two metrics:

- **Context**: estimated replayed transcript size (drives long-conversation warnings)
- **Cost**: lifetime billed usage, broken into **input** and **output** sub-totals

The label is "Cost" rather than "Lifetime usage". Input and output are both visible; reasoning/cache token sub-metrics may surface in admin/debug UI but do not need to appear in the primary chat header.

### 4. Reasoning-degradation reason is per-message and visually surfaced

When a turn ends up without reasoning even though the agent setting is enabled, the reason is stored per-message (machine-readable) and surfaced visually in the chat UI on that specific message (not just in admin/debug tooling).

Concretely: a `reasoning_skip_reason` (or similar) column on `messages`, populated when the system chose not to use reasoning for that turn, plus a small visual indicator (icon + tooltip) on the message in the chat UI explaining why thinking was unavailable.
