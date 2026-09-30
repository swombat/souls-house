# Upgrade Conversational Approach

**Spec:** `docs/requirements/260427-01-upgrade-conversational-approach.md`
**Date:** 2026-04-27

## Goal

Make multi-turn, multi-agent chats behave consistently across providers (Anthropic, Gemini, OpenRouter/OpenAI, xAI) for thinking/reasoning models. Concretely:

1. Persist provider replay metadata (signatures, thought signatures, reasoning_details) so reasoning continues across turns.
2. Replace the global `Chat#thinking_compatible_for?` gate with provider-specific, per-turn rules.
3. Unify the persistence path used by `AiResponseJob` and `ManualAgentResponseJob` / `AllAgentsResponseJob` so there is exactly one place that converts a `RubyLLM::Message` into a stored `Message`.
4. Split `total_tokens` into a `context` metric (active replayed transcript) and a `cost` metric (lifetime billed input/output).
5. Record per-message reasoning-skip reasons and surface them in the UI.

The whole upgrade is additive against an existing production-copy database with hundreds of legacy assistant messages. No backfill, no fabrication, no service objects.

---

## Schema Changes

One additive migration:

```ruby
# db/migrate/20260427120000_upgrade_conversation_replay.rb
class UpgradeConversationReplay < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :replay_payload,        :jsonb
    add_column :messages, :cached_tokens,         :integer
    add_column :messages, :cache_creation_tokens, :integer
    add_column :messages, :provider_model_id,     :string
    add_column :messages, :reasoning_skip_reason, :string

    add_column :tool_calls, :replay_payload, :jsonb

    add_index :messages, :reasoning_skip_reason, where: "reasoning_skip_reason IS NOT NULL"
  end
end
```

Field semantics:

| Column                            | Purpose                                                                                                                                                                            |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `messages.replay_payload`         | Provider-shaped jsonb. Anthropic stores `{ "provider": "anthropic", "thinking": { "type": "thinking", "thinking": "...", "signature": "..." } }`. OpenRouter stores `{ "provider": "openrouter", "reasoning_details": [...] }`. Gemini stores top-level signatures (tool-level signatures live on `tool_calls.replay_payload`). |
| `messages.cached_tokens`          | Provider-reported cached input tokens (Anthropic prompt cache reads, OpenAI cache hits).                                                                                            |
| `messages.cache_creation_tokens`  | Provider-reported cache write tokens.                                                                                                                                              |
| `messages.provider_model_id`      | Exact provider model used for this turn (e.g. `claude-opus-4-5-20251101`). Distinct from `model_id_string` (which is the OpenRouter-shaped routing key).                            |
| `messages.reasoning_skip_reason`  | Enum-string. `nil` means no skip. See "Reasoning skip reasons" below.                                                                                                              |
| `tool_calls.replay_payload`       | Provider continuity blob for a tool call. Used for Gemini `thoughtSignature` per function-call.                                                                                    |

`thinking_text`, `thinking_signature`, `thinking_tokens`, `input_tokens`, `output_tokens`, `tools_used` all stay. `thinking_signature` becomes a thin convenience accessor that points into `replay_payload` for Anthropic; we keep the column for backwards compatibility on existing reads but the new write path persists into `replay_payload` only. `thinking_text` continues to be the canonical display field.

The existing `tool_calls` table already has `arguments`, `metadata`, `name`, `tool_call_id`, `message_id`. We use `replay_payload` for provider-specific replay info and continue using `metadata` for app-level info if needed.

---

## Persistence Contract

Today, two paths fight each other:

- `AiResponseJob` calls `chat.complete`, lets RubyLLM persist via `on_end_message`, then `finalize_message!` does a partial second `update!`.
- `ManualAgentResponseJob` / `AllAgentsResponseJob` create a blank `Message`, stream into it, and `finalize_message!` writes content/thinking/tokens.

Both end up calling `StreamsAiResponse#finalize_message!`. That is the right place to consolidate. We keep the concern, but we move the field-by-field conversion onto `Message` itself, so the concern becomes a thin orchestrator.

### `Message.absorb!` (the single contract)

Add to `app/models/message.rb`:

```ruby
# Absorbs a RubyLLM::Message into this assistant message, persisting all
# fields needed for display, replay, and accounting in one update.
# Called from both AiResponseJob (single-agent) and the multi-agent jobs.
def absorb!(ruby_llm_message, agent: nil, fallback_content: nil, tool_names_used: [])
  payload = Message::ProviderPayload.new(ruby_llm_message)

  attrs = {
    content:                payload.content.presence || fallback_content.presence || content,
    thinking_text:          payload.thinking_text,
    thinking_tokens:        payload.thinking_tokens,
    input_tokens:           payload.input_tokens,
    output_tokens:          payload.output_tokens,
    cached_tokens:          payload.cached_tokens,
    cache_creation_tokens:  payload.cache_creation_tokens,
    model_id_string:        ruby_llm_message.model_id,
    provider_model_id:      payload.provider_model_id,
    replay_payload:         payload.replay_payload,
    tools_used:             tool_names_used.uniq.presence || tools_used,
  }

  attrs[:content] = self.class.strip_leading_timestamp(attrs[:content])
  update!(attrs.compact)

  Message::ToolCallSync.persist!(self, ruby_llm_message)
  self
end
```

`Message::ProviderPayload` (a small PORO under `app/models/message/provider_payload.rb`) inspects `ruby_llm_message.raw` plus the helper attrs RubyLLM exposes (`thinking`, `input_tokens`, `output_tokens`, `model_id`, etc.) and builds the provider-specific `replay_payload` shape. It is a Plain Old Ruby Object that lives under the `Message` namespace — not a service object — and exists purely as a translator between `RubyLLM::Message` and our columns. One file per provider isn't necessary; case-on-provider in one file is fine until it grows.

`Message::ToolCallSync` is a small module (`extend self`) that walks `ruby_llm_message.tool_calls` (if any) and upserts `ToolCall` rows with `replay_payload` populated. It runs in the same transaction implicitly because we're inside `update!`.

### Concern simplification

`StreamsAiResponse#finalize_message!` becomes:

```ruby
def finalize_message!(ruby_llm_message)
  return unless @ai_message
  flush_all_buffers

  @ai_message.absorb!(
    ruby_llm_message,
    agent: @agent,
    fallback_content: @content_accumulated.presence || @ai_message.reload.content,
    tool_names_used: @tools_used,
  )

  handle_empty_response!(ruby_llm_message) if @ai_message.content.blank?
  deduplicate_message!
  @message_finalized = true

  ModerateMessageJob.perform_later(@ai_message) if @ai_message.content.present?
  FixHallucinatedToolCallsJob.perform_later(@ai_message) if @ai_message.fixable
end
```

The empty-response handling (Gemini SAFETY etc.) stays as a private method. The `update!` no longer happens twice. The logic that decided "do I need to populate thinking_text/signature" moves into `ProviderPayload`, where it belongs.

Both `AiResponseJob` and the multi-agent jobs already call `finalize_message!`. After this change, they share a real contract instead of just a method name.

### Tool-call continuity

`Message::ToolCallSync.persist!` is the only place that writes `tool_calls` rows during normal AI responses. (Hallucination recovery in `Message#fix_hallucinated_tool_calls!` continues to write inline messages but does not interact with `tool_calls`.)

```ruby
module Message::ToolCallSync
  extend self

  def persist!(message, ruby_llm_message)
    Array(ruby_llm_message.tool_calls).each do |tc|
      message.tool_calls.find_or_create_by!(tool_call_id: tc.id) do |row|
        row.name           = tc.name
        row.arguments      = tc.arguments
        row.replay_payload = extract_replay_payload(tc)
      end
    end
  end

  def extract_replay_payload(tool_call)
    sig = tool_call.respond_to?(:thought_signature) && tool_call.thought_signature
    return nil unless sig.present?
    { "provider" => "gemini", "thought_signature" => sig }
  end
end
```

The Gemini-specific extraction lives here because Gemini is the only provider that surfaces a per-tool-call signature today. If OpenAI or Anthropic add equivalent metadata later, extend this module.

`tools_used` is unchanged — it stays a flat array of names/URLs for the UI. Replay continuity reads `tool_calls.replay_payload`.

---

## Replay Rules per Provider

Replace `Chat#thinking_compatible_for?` with `Message#replay_for(provider, current_agent:)`. This lives on `Message` because each message decides its own shape. `Chat#format_message_for_context` calls it.

```ruby
class Message
  # Returns the hash to pass into RubyLLM as a replayed message,
  # or nil if this message should be skipped entirely.
  def replay_for(provider, current_agent:)
    Message::Replay.new(self, provider: provider, current_agent: current_agent).to_h
  end
end
```

`Message::Replay` is a small PORO under `app/models/message/replay.rb`. It returns the right shape per provider and records why reasoning was dropped (so the caller can surface it).

### Per-provider rules

**Anthropic** (`provider == :anthropic`):

- If `agent_id == current_agent.id` and `replay_payload.dig("anthropic", "thinking", "signature")` is present, include the thinking block (`{ thinking:, thinking_signature: }`).
- If `agent_id == current_agent.id` and there's no signature but there IS thinking text — drop the thinking block. Replay assistant text only. Set `reasoning_skip_reason = "legacy_no_signature"` on this message if it isn't already set.
- If `agent_id != current_agent.id` — replay as user-shaped content (other agent's message). Never include thinking blocks.
- If tool calls exist on this message and Anthropic continuity needs them, also serialize them into the replay (RubyLLM handles this via `add_message`; we just persist the `tool_calls` rows so RubyLLM can find them).

**Gemini** (`provider == :gemini`):

- For same-agent assistant turns, include `thought_signature` per tool call from `tool_calls.replay_payload`.
- Top-level thinking text is replayable but Gemini does not require Anthropic-style signatures on it. Include `thinking_text` if present.
- Other agents → user-shaped content.

**OpenRouter / OpenAI / xAI** (`provider == :openrouter, :openai, :xai`):

- For same-agent assistant turns, include `replay_payload.dig(provider.to_s, "reasoning_details")` if persisted. Pass through unchanged.
- Do NOT block on Anthropic-style signatures. If `replay_payload` is empty, replay assistant content alone — that's valid for these providers.
- Other agents → user-shaped content.

### Other agents' messages

In a group chat, the current `format_message_for_context` already converts other-agent messages to user-shaped content with `[Agent Name]:` prefixes. That stays. The change is: the thinking branch at the bottom of `format_message_for_context` only runs when `message.agent_id == current_agent.id`, AND it now goes through `Message::Replay` so it picks up provider-specific shape.

`Chat#format_message_for_context` becomes:

```ruby
def format_message_for_context(message, current_agent, timezone, ...)
  base = build_text_and_files(message, current_agent, timezone, ...)  # existing logic, unchanged

  if message.role == "assistant" && message.agent_id == current_agent.id
    replay_extras = message.replay_for(provider_for(current_agent), current_agent: current_agent)
    base.merge(replay_extras)
  else
    base.merge(role: message.role == "assistant" ? "user" : message.role)
  end
end
```

`provider_for(current_agent)` resolves to the same provider config the job will use (`ResolvesProvider.resolve_provider(current_agent.model_id)[:provider]`). The job and the context-builder must agree on the provider, so we pass it in from the job.

### Replacing `thinking_compatible_for?`

`Chat#thinking_compatible_for?` is deleted. The current "if any historical turn lacks a signature, disable thinking everywhere" rule is wrong. Replacement:

- Thinking on the new turn is enabled iff the agent has `uses_thinking?` and the model supports thinking.
- Each historical turn handles its own replay shape via `Message::Replay`. Legacy turns drop their thinking block; new turns carry valid signatures; the conversation recovers organically as new messages accumulate.
- The Anthropic API-key precheck stays (that's about the current outbound call, not historical replay).

In `ManualAgentResponseJob` and `AllAgentsResponseJob`:

```ruby
@use_thinking = agent.uses_thinking? && Chat.supports_thinking?(agent.model_id)
```

Same shape in `AiResponseJob` (which already routes through RubyLLM's `on_new_message`). The thinking-compatibility branch is gone.

---

## Reasoning Skip Reasons

`messages.reasoning_skip_reason` enum-string. Set in two places:

1. By `Message::Replay` when it drops a thinking block during replay (per-message annotation, persisted on the historical message).
2. By the response job when it decides not to enable thinking for the *current* turn (set on the new assistant message before/during `absorb!`).

Values:

| Value                              | Meaning                                                                                          |
| ---------------------------------- | ------------------------------------------------------------------------------------------------ |
| `legacy_no_signature`              | Anthropic message with thinking text but no signature; signature dropped on replay.              |
| `provider_no_replayable_reasoning` | Provider returned no reasoning_details / signature / thought_signature. Replay omits reasoning.  |
| `tool_call_continuity_missing`     | Gemini tool-using message with no `thought_signature` on the `tool_calls` row.                   |
| `model_lacks_thinking_support`     | Agent has thinking enabled but model isn't on the supported list.                                |
| `anthropic_key_unavailable`        | Anthropic direct-API path needed but key isn't configured.                                       |

Surface in UI: a small phosphor icon (`Lightbulb` with a slash, or `EyeSlash`) next to the message metadata, with a tooltip that maps the enum to human text. Add `reasoning_skip_reason` and `reasoning_skip_reason_label` to `Message#json_attributes`. Render in `MessageBubble.svelte` next to the timestamp/tools row.

---

## Token Accounting

Replace `Chat#total_tokens` with two methods.

### `Chat#cost_tokens`

Lifetime billed usage. Cheap aggregation over persisted columns:

```ruby
def cost_tokens
  result = messages.unscope(:order).pick(
    Arel.sql("COALESCE(SUM(input_tokens), 0)"),
    Arel.sql("COALESCE(SUM(output_tokens), 0)"),
    Arel.sql("COALESCE(SUM(thinking_tokens), 0)"),
    Arel.sql("COALESCE(SUM(cached_tokens), 0)"),
    Arel.sql("COALESCE(SUM(cache_creation_tokens), 0)"),
  )
  {
    input:          result[0],
    output:         result[1],
    reasoning:      result[2],
    cached:         result[3],
    cache_creation: result[4],
  }
end
```

### `Chat#context_tokens`

Estimated current replayed transcript size. The pragmatic algorithm:

1. Take the most recent assistant message from any agent that has an `input_tokens` value. That value is the provider's count of "what we just sent the model" — including system prompt, all replayed messages, and tools. It is the truest estimate available.
2. If no such message exists yet (chat hasn't had an assistant turn), fall back to a rough estimate: sum `chars / 4` across user messages.

```ruby
def context_tokens
  last_with_count = messages.unscope(:order)
                            .where(role: "assistant")
                            .where.not(input_tokens: nil)
                            .order(created_at: :desc)
                            .limit(1)
                            .pick(:input_tokens)
  return last_with_count if last_with_count

  # No assistant turn yet — estimate from user content
  total_chars = messages.where(role: "user").sum("LENGTH(COALESCE(content, ''))")
  (total_chars / 4.0).ceil
end
```

This is honest: it tracks what the provider actually treats as the prompt. It naturally excludes hidden reasoning that isn't replayed (because the provider doesn't bill it as input on the next turn) and includes hidden reasoning that IS replayed (because the provider DOES bill it). No tokenizer dependency required. We do not introduce `tiktoken_ruby` for this phase — the provider's own count is more accurate per-provider than any tokenizer estimate.

### JSON shape

`Chat#json_attributes` replaces `:total_tokens` with `:context_tokens` and `:cost_tokens`. Drop `total_tokens` from json output. The chat header reads the new keys.

### Long-conversation thresholds

The header thresholds (`amber: 100_000`, `red: 150_000`, `critical: 200_000`) now apply to `context_tokens` only, which is the correct metric. Existing thresholds keep their numerical values; they were always intended as "is the prompt getting big" thresholds, just applied to the wrong number.

---

## UI Changes

### `app/frontend/lib/components/chat/ChatHeader.svelte`

Replace:

```svelte
<span class="ml-2 text-xs">({formatTokenCount(totalTokens)} tokens)</span>
```

with:

```svelte
<span class="ml-2 text-xs">
  Context: {formatTokenCount(contextTokens)}
  · Cost: in {formatTokenCount(costTokens.input)} / out {formatTokenCount(costTokens.output)}
</span>
```

Props change: `totalTokens` → `contextTokens` + `costTokens`. The warning-level `$derived` reads from `contextTokens`. The wording for badges stays ("Long conversation" / "Very long" / "Extremely long").

`app/frontend/pages/chats/show.svelte` passes the new props through (sourced from `chat.context_tokens` and `chat.cost_tokens`). The single existing call site should be straightforward to update.

### `app/frontend/lib/components/chat/MessageBubble.svelte`

Add a reasoning-skip indicator next to the existing meta row (where tools/timestamp render):

```svelte
{#if message.reasoning_skip_reason}
  <span title={reasoningSkipTooltip(message.reasoning_skip_reason)}
        class="text-muted-foreground inline-flex items-center">
    <LightbulbFilament size={14} />
  </span>
{/if}
```

`reasoningSkipTooltip` is a small helper in `chat-utils.js`:

```js
const REASONING_SKIP_LABELS = {
  legacy_no_signature: "Thinking unavailable: this turn was created before signed thinking blocks were stored.",
  provider_no_replayable_reasoning: "Thinking unavailable: provider did not return replayable reasoning.",
  tool_call_continuity_missing: "Thinking unavailable: tool-call continuity metadata is missing.",
  model_lacks_thinking_support: "Thinking unavailable: this model does not support extended thinking.",
  anthropic_key_unavailable: "Thinking unavailable: Anthropic API key not configured.",
};
export function reasoningSkipTooltip(reason) {
  return REASONING_SKIP_LABELS[reason] || "Thinking was unavailable for this message.";
}
```

`Message#json_attributes` exposes `reasoning_skip_reason` plus `reasoning_skip_reason_label` (so the server controls copy if it changes).

---

## Migration & Legacy Data

- The migration is purely additive (`add_column`). No data is rewritten. The development DB and production DB keep all existing rows.
- We do not backfill `replay_payload` on historical messages. We do not invent signatures.
- Legacy Anthropic assistant turns naturally fall into `legacy_no_signature` the first time they are replayed. `Message::Replay` stamps `reasoning_skip_reason` on them at replay time (via `update_column(:reasoning_skip_reason, "legacy_no_signature")`). This is a write at read time, which is a small Rails convention violation, but it's idempotent and lets the UI show the indicator without a separate backfill pass. If we want to avoid this entirely, we can skip the persistence and recompute on demand — the spec accepts either; recommend the persisted version because it's diagnosable.
- Forking via `Chat#fork_with_title!` already copies `tools_used`, content, agent_id, tokens. Add `replay_payload`, `cached_tokens`, `cache_creation_tokens`, `provider_model_id`, `reasoning_skip_reason`, `thinking_text`, `thinking_signature`, `thinking_tokens` to the copy block. Tool calls also need to be copied so replay continuity is preserved on the fork.
- `Chat#total_tokens` callers: search the codebase. Currently used in `Chat#json_attributes` and the chat header. Remove it; replace with the new pair.

---

## Testing Strategy

All Ruby tests use VCR — no mocks. Existing repo conventions: `require "support/vcr_setup"`, cassettes under `test/vcr_cassettes/`.

### Unit tests

`test/models/message/provider_payload_test.rb`

- Given a fake `RubyLLM::Message` with Anthropic raw shape, builds `replay_payload` with `thinking.signature`.
- Given OpenRouter raw shape with `reasoning_details`, builds `replay_payload` with reasoning_details intact.
- Given Gemini raw with `thoughtSignature` on a tool call, builds `tool_calls.replay_payload` for that tool call.
- Cached/cache_creation tokens read correctly from each provider's raw shape.

We do not mock `RubyLLM::Message` — we instantiate real ones from fixture JSON pulled from VCR cassettes.

`test/models/message/replay_test.rb`

- Anthropic, same agent, signed thinking → returns `{ role: :assistant, content:, thinking:, thinking_signature: }`.
- Anthropic, same agent, thinking text but no signature → returns `{ role: :assistant, content: }` and stamps `legacy_no_signature` on the message.
- Anthropic, other agent → returns user-shaped content with `[Name]:` prefix.
- OpenRouter, same agent, no replay_payload → returns `{ role: :assistant, content: }` with no skip reason (this is normal for OpenRouter).
- OpenRouter, same agent, with reasoning_details → returns `{ role: :assistant, content:, reasoning_details: [...] }`.
- Gemini, same agent, tool calls with signatures → tool calls are included with `thought_signature`.

`test/models/chat_test.rb`

- `context_tokens` returns the input_tokens of the most recent assistant message.
- `context_tokens` falls back to char/4 estimate when no assistant message exists.
- `cost_tokens` returns hash with all five keys, summing across messages, treating nils as zero.
- `Chat#thinking_compatible_for?` is gone (assert no longer responds to it).

### Integration tests through jobs

`test/jobs/ai_response_job_test.rb`, `test/jobs/manual_agent_response_job_test.rb`, `test/jobs/all_agents_response_job_test.rb` — each uses VCR cassettes against the real provider and verifies the persisted shape on the resulting `Message` row.

Cassettes to record (one per scenario):

- `anthropic_thinking_two_turn` — turn 1 with thinking enabled, turn 2 same agent. Asserts: turn 1 persisted `replay_payload.anthropic.thinking.signature`; turn 2 succeeded with thinking enabled (the second outgoing API call body must include the prior turn's thinking block with signature).
- `anthropic_thinking_with_other_agent` — group chat, agent A speaks (thinking), agent B speaks (no thinking, model doesn't support it), agent A's next turn keeps thinking. Asserts: agent B's message replayed as user-shaped content; agent A's thinking was not disabled by agent B's existence.
- `openrouter_thinking_no_signature` — OpenRouter Grok or DeepSeek reasoning model, two-turn. Asserts: reasoning_details persisted on turn 1, replayed on turn 2, no `legacy_no_signature` flag (because OpenRouter doesn't require Anthropic-style signatures).
- `gemini_tool_call_continuity` — Gemini turn that uses a tool, then a follow-up turn. Asserts: `tool_calls.replay_payload` contains `thought_signature`; the second outbound request includes the signature.
- `legacy_anthropic_no_signature_recovers` — fixture-seeded chat with an Anthropic assistant message that has thinking_text but no signature, plus a fresh user turn. Asserts: the legacy message replays without thinking; the new turn carries thinking and signature; the legacy message gets `reasoning_skip_reason: "legacy_no_signature"` stamped.

### Token metric tests

`test/integration/chat_token_display_test.rb`

- After running through `anthropic_thinking_two_turn`, `context_tokens` equals turn 2's `input_tokens` (last assistant message), not the cumulative sum.
- After the same flow, `cost_tokens[:input]` and `cost_tokens[:output]` are the per-turn sums.
- The chat sidebar/header JSON includes `context_tokens` and `cost_tokens` and does not include `total_tokens`.

### Legacy regression

`test/models/message/legacy_replay_test.rb`

- A `Message` with `thinking_text` present and no `replay_payload` and no `thinking_signature`, when replayed for Anthropic, returns no thinking block and stamps `legacy_no_signature`. The next turn (newly recorded with full payload) replays its thinking block normally.
- Test that thousands of historical messages don't cause a global thinking disable. (One assertion: a chat with 10 such legacy messages still allows a new Anthropic turn to enable thinking.)

### Direct provider verification

The five cassettes above ARE the direct provider verification. Recording requires real API keys; replay does not. Cassettes get filtered for keys via existing VCR config.

---

## Acceptance Criteria → Tests

| # | Acceptance criterion                                                                              | Test location                                                       |
| - | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 1 | Two-turn Anthropic conversation keeps thinking enabled on turn 2                                  | `manual_agent_response_job_test.rb` — `anthropic_thinking_two_turn` |
| 2 | Multi-agent: another agent's lack of reasoning metadata doesn't disable agent A's thinking         | `manual_agent_response_job_test.rb` — `anthropic_thinking_with_other_agent` |
| 3 | New assistant messages persist signatures and reasoning token metadata                             | `provider_payload_test.rb` and all integration cassettes            |
| 4 | Tool calls persist when continuity needs them (Gemini)                                             | `manual_agent_response_job_test.rb` — `gemini_tool_call_continuity` |
| 5 | Legacy conversations no longer fail through silent reasoning drop                                  | `legacy_replay_test.rb`                                             |
| 6 | Primary chat header label = active context, not lifetime billing                                   | `chat_token_display_test.rb` and Svelte component (manual or playwright) |
| 7 | Lifetime usage available separately for reporting                                                  | `chat_test.rb#cost_tokens`                                          |
| 8 | Reasoning tokens stored separately, do not inflate context unless replayed                         | `provider_payload_test.rb` (cached_tokens, thinking_tokens) + `chat_test.rb#context_tokens` |
| 9 | Multi-agent path and ordinary chat path share persistence semantics                                | All three job tests assert the same `Message#absorb!` is called and produces identical column shapes |
| 10 | RubyLLM stays in place, not the source of ambiguity                                                | Implicit — `Message#absorb!` is the single owner of column writes; `to_llm` still routes through RubyLLM |

---

## Files Touched

New files:

- `db/migrate/20260427120000_upgrade_conversation_replay.rb`
- `app/models/message/provider_payload.rb`
- `app/models/message/replay.rb`
- `app/models/message/tool_call_sync.rb`
- `test/models/message/provider_payload_test.rb`
- `test/models/message/replay_test.rb`
- `test/models/message/legacy_replay_test.rb`
- `test/integration/chat_token_display_test.rb`
- `test/vcr_cassettes/anthropic_thinking_two_turn/...`
- `test/vcr_cassettes/anthropic_thinking_with_other_agent/...`
- `test/vcr_cassettes/openrouter_thinking_no_signature/...`
- `test/vcr_cassettes/gemini_tool_call_continuity/...`
- `test/vcr_cassettes/legacy_anthropic_no_signature_recovers/...`

Modified:

- `app/models/message.rb` — adds `absorb!`, `replay_for`. Removes `thinking_signature` writes from `update!` callers (all go via `absorb!` now).
- `app/models/chat.rb` — drops `thinking_compatible_for?` and `total_tokens`. Adds `context_tokens`, `cost_tokens`. Updates `format_message_for_context` to delegate to `Message#replay_for`. Updates `fork_with_title!` to copy new columns.
- `app/jobs/concerns/streams_ai_response.rb` — `finalize_message!` becomes a thin shell around `Message#absorb!`.
- `app/jobs/manual_agent_response_job.rb` — drops `thinking_compatible_for?` call. Sets `reasoning_skip_reason` on `@ai_message` when thinking is unavailable.
- `app/jobs/all_agents_response_job.rb` — same as above.
- `app/jobs/ai_response_job.rb` — minimal; just inherits the consolidated `finalize_message!`.
- `app/frontend/lib/components/chat/ChatHeader.svelte` — Context / Cost copy.
- `app/frontend/lib/components/chat/MessageBubble.svelte` — reasoning-skip icon.
- `app/frontend/lib/chat-utils.js` — `reasoningSkipTooltip` helper.
- `app/frontend/pages/chats/show.svelte` — pass `contextTokens` / `costTokens` to header.
- `app/models/chat.rb` `json_attributes` — replace `:total_tokens` with `:context_tokens, :cost_tokens`.

---

## Out of Scope (explicit)

- No agent memory / summary / whiteboard changes.
- No RubyLLM replacement.
- No tokenizer dependency (tiktoken_ruby is rejected for this phase — `input_tokens` from the last response is more accurate).
- No backfill of historical `replay_payload`.
- No new admin/debug UI beyond the per-message reasoning-skip indicator already in the chat.
- No change to streaming UX.

---

## Open Risks / Notes for Implementation

1. **`tool_calls` rows during streaming**: today, tool call rows are not consistently written for the multi-agent jobs. After this change, `Message::ToolCallSync.persist!` runs at `absorb!` time. If `absorb!` is called once per response cycle (which it is — `on_end_message` fires once per assistant message), this works. Verify tool_calls don't get duplicated across retries — `find_or_create_by!(tool_call_id:)` handles that.
2. **`reasoning_skip_reason` write during read**: `Message::Replay` stamps the column on legacy messages when they're first read. This is a side-effect during context-building. Acceptable trade-off for diagnosability. If it causes problems (e.g., during read replicas), drop the persistence and recompute. Document the choice in the model.
3. **`provider_for(current_agent)` symmetry**: the context-builder and the response job MUST agree on which provider is used. The job calls `llm_provider_for(agent.model_id, ...)`. The same call should drive `format_message_for_context`. Pass `provider:` explicitly into `chat.build_context_for_agent`.
4. **`replay_payload` vs `thinking_signature` column**: we keep the legacy column for now (not destructive). New writes go through `replay_payload`. `Message#thinking_signature` becomes a reader: `replay_payload.dig("anthropic", "thinking", "signature") || self[:thinking_signature]`. Old data still surfaces. After 1–2 cycles of confirmed forward correctness, a future cleanup migration can drop the column. Out of scope for this spec.
