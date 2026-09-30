# Upgrade Conversational Approach

**Spec:** `docs/requirements/260427-01-upgrade-conversational-approach.md`
**Date:** 2026-04-27 (revision d)

## Goal

Make multi-turn, multi-agent chats behave consistently across providers (Anthropic, Gemini, OpenRouter/OpenAI, xAI) for thinking/reasoning models. Concretely:

1. Persist provider replay metadata so reasoning continues across turns.
2. Replace the global `Chat#thinking_compatible_for?` gate with per-provider, per-turn rules.
3. Unify the persistence path used by `AiResponseJob`, `ManualAgentResponseJob`, and `AllAgentsResponseJob` so a `RubyLLM::Message` becomes a stored `Message` in exactly one place.
4. Split `total_tokens` into a `context` metric (current replayed prompt) and a `cost` metric (lifetime billed input/output).
5. Record per-message reasoning-skip reasons and surface them in the chat UI.

## Diagnosis

Two persistence paths fight each other:

- `AiResponseJob` (`app/jobs/ai_response_job.rb:33`) lets RubyLLM persist on `on_end_message`, then `finalize_message!` overwrites with a partial second `update!`.
- `ManualAgentResponseJob` / `AllAgentsResponseJob` create a blank `Message`, stream into it, and `finalize_message!` writes content/thinking/tokens, dropping `thinking_signature`, `thinking_tokens`, cached/cache-creation tokens, and tool-call replay metadata.

The result: turn 1 stores visible thinking, turn 2 has no signature, `Chat#thinking_compatible_for?` (`app/models/chat.rb:771`) returns false, and thinking silently dies for the rest of the conversation. The same gate also misfires for Gemini, OpenRouter, OpenAI, and xAI, none of which need Anthropic-style signatures.

## Schema

```ruby
class UpgradeConversationReplay < ActiveRecord::Migration[8.1]
  def up
    add_column :messages,   :replay_payload,        :jsonb
    add_column :messages,   :cached_tokens,         :integer
    add_column :messages,   :cache_creation_tokens, :integer
    add_column :messages,   :reasoning_skip_reason, :string
    add_column :tool_calls, :replay_payload,        :jsonb

    add_index :messages, :reasoning_skip_reason, where: "reasoning_skip_reason IS NOT NULL"

    Message.where.not(thinking_signature: [ nil, "" ]).find_each do |msg|
      payload = {
        "provider" => "anthropic",
        "thinking" => {
          "text" => msg.thinking_text,
          "signature" => msg.thinking_signature,
        },
      }
      msg.update_columns(replay_payload: payload)
    end

    remove_column :messages, :thinking_signature
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

| Column | Purpose |
| ------ | ------- |
| `messages.replay_payload` | Provider-shaped jsonb. Anthropic: `{ "provider": "anthropic", "thinking": { "text", "signature" } }`. OpenRouter/OpenAI/xAI: `{ "provider": "openrouter", "reasoning_details": [...] }`. Gemini top-level: `{ "provider": "gemini", "thought_signature": "..." }` (per-tool signatures live on `tool_calls.replay_payload`). |
| `messages.cached_tokens` | Provider-reported cached input tokens. |
| `messages.cache_creation_tokens` | Provider-reported cache write tokens. |
| `messages.reasoning_skip_reason` | Set only at message creation/finalization when the *current* turn skipped reasoning. Legacy historical skips are computed on read (see below). |
| `tool_calls.replay_payload` | Per-tool continuity blob. Currently used for Gemini `thought_signature`. |

The migration relocates existing `thinking_signature` values into `replay_payload`, then drops the column. One source of truth. Rollback is irreversible — relocating data into jsonb and back is theater in production.

`messages.model_id_string` already stores `RubyLLM::Message#model_id`, which on Anthropic direct-API calls is the resolved provider model (`claude-opus-4-5-20251101`) and on OpenRouter calls is the OpenRouter routing key. That is the same string `provider_model_id` would store. Don't add the column.

Implementation must verify that `Message#model_id_string` (populated by RubyLLM's `acts_as_message` from the provider response) reflects the resolved provider model id used for the call, distinct from the chat-level configured model id. If RubyLLM doesn't populate it that way for some provider, store the resolved provider model in `replay_payload[:provider_model]` instead — no column added.

`thinking_text`, `thinking_tokens`, `input_tokens`, `output_tokens`, `tools_used` stay. `thinking_text` is the canonical display field. `Message#thinking_signature` becomes a delegating reader on `replay_payload`.

## Persistence Contract

`StreamsAiResponse#finalize_message!` becomes a thin shell. Field-by-field translation lives on `Message` as instance methods.

```ruby
class Message
  def record_provider_response!(ruby_llm_message, tool_names: [])
    update!(
      content:               extract_content(ruby_llm_message) || content,
      thinking_text:         ruby_llm_message.thinking&.text,
      thinking_tokens:       ruby_llm_message.thinking_tokens,
      input_tokens:          ruby_llm_message.input_tokens,
      output_tokens:         ruby_llm_message.output_tokens,
      cached_tokens:         extract_cached_tokens(ruby_llm_message),
      cache_creation_tokens: extract_cache_creation_tokens(ruby_llm_message),
      model_id_string:       ruby_llm_message.model_id,
      replay_payload:        build_replay_payload(ruby_llm_message),
      tools_used:            tool_names.uniq.presence || tools_used,
    )
    sync_tool_calls_from(ruby_llm_message)
    self
  end

  def sync_tool_calls_from(ruby_llm_message)
    Array(ruby_llm_message.tool_calls).each do |tc|
      tool_calls.find_or_create_by!(tool_call_id: tc.id) do |row|
        row.name           = tc.name
        row.arguments      = tc.arguments
        row.replay_payload = gemini_thought_signature(tc)
      end
    end
  end

  private

  def extract_content(rlm)
    self.class.strip_leading_timestamp(rlm.content.to_s).presence
  end

  def extract_cached_tokens(rlm)
    raw = rlm.raw.is_a?(Hash) ? rlm.raw : {}
    raw.dig("usage", "cache_read_input_tokens") ||
      raw.dig("usage", "prompt_tokens_details", "cached_tokens")
  end

  def extract_cache_creation_tokens(rlm)
    raw = rlm.raw.is_a?(Hash) ? rlm.raw : {}
    raw.dig("usage", "cache_creation_input_tokens")
  end

  def build_replay_payload(rlm)
    case rlm.provider&.to_sym
    when :anthropic                 then anthropic_replay_payload(rlm)
    when :gemini                    then gemini_replay_payload(rlm)
    when :openrouter, :openai, :xai then openrouter_replay_payload(rlm)
    end
  end

  def anthropic_replay_payload(rlm)
    sig = rlm.thinking&.signature
    return nil unless sig.present?
    { "provider" => "anthropic", "thinking" => { "text" => rlm.thinking.text, "signature" => sig } }
  end

  def gemini_replay_payload(rlm)
    sig = rlm.respond_to?(:thought_signature) && rlm.thought_signature
    return nil unless sig.present?
    { "provider" => "gemini", "thought_signature" => sig }
  end

  def openrouter_replay_payload(rlm)
    raw = rlm.raw.is_a?(Hash) ? rlm.raw : {}
    details = raw.dig("choices", 0, "message", "reasoning_details")
    return nil if details.blank?
    { "provider" => "openrouter", "reasoning_details" => details }
  end

  def gemini_thought_signature(tool_call)
    sig = tool_call.respond_to?(:thought_signature) && tool_call.thought_signature
    return nil unless sig.present?
    { "provider" => "gemini", "thought_signature" => sig }
  end
end
```

`StreamsAiResponse#finalize_message!`:

```ruby
def finalize_message!(ruby_llm_message)
  return unless @ai_message
  flush_all_buffers

  if @ai_message.content.blank?
    @ai_message.content = @content_accumulated.presence ||
                          empty_response_fallback(ruby_llm_message) ||
                          @ai_message.reload.content
  end

  @ai_message.record_provider_response!(ruby_llm_message, tool_names: @tools_used)

  deduplicate_message!
  @message_finalized = true

  ModerateMessageJob.perform_later(@ai_message)         if @ai_message.content.present?
  FixHallucinatedToolCallsJob.perform_later(@ai_message) if @ai_message.fixable
end

private

def empty_response_fallback(rlm)
  return nil if rlm.content.present? || rlm.output_tokens.to_i > 0
  raw    = rlm.raw.is_a?(Hash) ? rlm.raw : {}
  reason = raw.dig("candidates", 0, "finishReason") || raw.dig("choices", 0, "finish_reason")
  case reason
  when "SAFETY" then "_The AI was unable to respond due to content safety filters._"
  when nil      then "_The AI returned an empty response._"
  else               "_The AI was unable to complete its response (reason: #{reason})._"
  end
end
```

One `update!` per response. One owner of column writes. The empty-response fallback (Gemini SAFETY etc.) lives in the streaming concern because the apology copy is UX, not data — the concern composes content, the model persists it.

`AllAgentsResponseJob`'s per-agent loop streams into a fresh `@ai_message` per agent and calls `finalize_message!` per agent — same contract, no special-casing.

## Replay Rules

Delete `Chat#thinking_compatible_for?`. Replace `Chat#format_message_for_context`'s thinking branch with a per-provider call on `Message`.

```ruby
class Message
  def replay_for(provider, current_agent:)
    return user_shaped_replay(current_agent) if agent_id != current_agent.id
    case provider
    when :anthropic                 then anthropic_replay
    when :gemini                    then gemini_replay
    when :openrouter, :openai, :xai then openrouter_replay
    end
  end

  private

  def anthropic_replay
    sig = replay_payload&.dig("thinking", "signature")
    return { role: :assistant, content: content } if sig.blank?
    { role: :assistant, content: content, thinking: thinking_text, thinking_signature: sig }
  end

  def gemini_replay
    payload = { role: :assistant, content: content }
    payload[:thinking] = thinking_text if thinking_text.present?
    payload[:tool_calls] = gemini_tool_call_replay if tool_calls.any?
    payload
  end

  def gemini_tool_call_replay
    tool_calls.order(:created_at).map do |tc|
      entry = { id: tc.tool_call_id, name: tc.name, arguments: tc.arguments }
      sig   = tc.replay_payload&.dig("thought_signature")
      entry[:thought_signature] = sig if sig.present?
      entry
    end
  end

  def openrouter_replay
    payload = { role: :assistant, content: content }
    details = replay_payload&.dig("reasoning_details")
    payload[:reasoning_details] = details if details.present?
    payload
  end

  def user_shaped_replay(current_agent)
    name = author_name
    { role: :user, content: "[#{name}]: #{content}" }
  end

  def thinking_signature
    replay_payload&.dig("thinking", "signature")
  end
end
```

### Per-provider rules

**Anthropic**: same agent + signed thinking → include thinking block. Same agent + unsigned legacy thinking → drop thinking block, replay assistant text only. Other agents → user-shaped content. The new turn always enables thinking when the agent has it on; only the *replay* of legacy turns drops their thinking blocks.

**Gemini**: same agent → assistant content, optional thinking text, plus a function-call entry for each persisted `tool_call`. Each function-call entry replays in the Gemini provider's expected shape (`id`, `name`, `arguments`, and `thought_signature` when persisted in `tool_calls.replay_payload`). When a tool call's `replay_payload` is missing or has no `thought_signature` (legacy or partially-migrated rows), the function-call entry is replayed *without* a `thought_signature` — never fabricated. The tool call still replays as a function call; only the signature is dropped on that specific entry. Other agents → user-shaped.

**OpenRouter / OpenAI / xAI**: same agent → assistant content + optional `reasoning_details`. Empty `replay_payload` is normal, not a skip. Other agents → user-shaped.

### Gemini tool-continuity degradation

Two layered behaviors when a Gemini chat replays prior turns from the current agent:

1. **Per-entry**: a tool call without a stored `thought_signature` replays as an unsigned function call. This is the tool-call analogue of the per-turn fallback for legacy thinking signatures: drop the missing artifact, keep the message.
2. **Per-turn flag**: when thinking is enabled on the *current* turn and at least one prior tool call from the current agent has no `thought_signature` in its `replay_payload`, the new assistant message is stamped with `reasoning_skip_reason: "tool_continuity_missing"`. This tells the user that thinking won't carry full continuity on this turn because earlier tool-call signatures are missing. Same per-turn philosophy as legacy thinking signatures: never disable thinking globally, just record what degraded on this specific turn.

`ManualAgentResponseJob` / `AllAgentsResponseJob` / `AiResponseJob` compute this flag before invoking the provider and pass it through to `record_provider_response!` (or set it on the message after persistence) so the column reflects the skip even though the provider call itself succeeded.

### Provider symmetry

The job and the context-builder must agree on the provider. Pass it explicitly:

```ruby
def build_context_for_agent(agent, provider:, thinking_enabled:, initiation_reason: nil)
  [ system_message_for(agent, initiation_reason: initiation_reason) ] +
    messages_context_for(agent,
      provider:             provider,
      thinking_enabled:     thinking_enabled,
      audio_tools_enabled:  audio_tools_available_for?(agent.model_id),
      pdf_input_supported:  self.class.supports_pdf_input?(agent.model_id))
end

def format_message_for_context(message, current_agent, timezone, provider:, thinking_enabled:, ...)
  base = build_text_and_files(message, current_agent, timezone, ...)
  return base unless message.role == "assistant" && thinking_enabled
  base.merge(message.replay_for(provider, current_agent: current_agent))
end
```

`ManualAgentResponseJob` and `AllAgentsResponseJob` resolve the provider via `llm_provider_for(agent.model_id, thinking_enabled: @use_thinking)` and pass `provider:` into `build_context_for_agent`. `AiResponseJob` passes the provider it resolved through `Chat#to_llm`.

### Thinking enablement

```ruby
@use_thinking = agent.uses_thinking? && Chat.supports_thinking?(agent.model_id)
```

No global compatibility gate. Each historical turn handles its own replay shape. Legacy Anthropic turns drop their thinking blocks; new turns carry valid signatures; conversations recover organically.

## Reasoning Skip Reasons

Four values, set on the *current* assistant message at finalization time when reasoning was unavailable or degraded:

| Value | Meaning |
| ----- | ------- |
| `legacy_no_signature` | Pre-upgrade Anthropic message with thinking text but no signature. Computed on read. |
| `tool_continuity_missing` | Gemini turn where thinking is enabled but at least one prior tool call from the current agent lacks a stored `thought_signature`. Stamped on the new turn's message. |
| `provider_unsupported` | Model/provider doesn't support replayable reasoning for this turn. |
| `anthropic_key_unavailable` | Anthropic direct API needed but key isn't configured. |

Legacy skips are read-time inferences, not stored:

```ruby
def reasoning_skip_reason
  self[:reasoning_skip_reason] || inferred_skip_reason
end

private

def inferred_skip_reason
  return nil unless role == "assistant"
  return "legacy_no_signature" if thinking_text.present? && replay_payload.blank?
  nil
end
```

No `update_column` in a read path. The column carries only explicit current-turn skips written by jobs. The reader composes both sources.

For `anthropic_key_unavailable`: jobs persist a stub assistant message with `reasoning_skip_reason: "anthropic_key_unavailable"` and a content message explaining the situation, instead of the current `broadcast_error + return`. This keeps the conversation in one shape.

`Message#json_attributes` exposes `reasoning_skip_reason` and `reasoning_skip_reason_label`.

## Token Accounting

Replace `Chat#total_tokens` with three methods: `cost_tokens`, `context_tokens`, `reasoning_tokens`. Only the first two appear in the chat header.

### `Chat#cost_tokens`

Lifetime billed input/output. The chat header shows two numbers:

```ruby
def cost_tokens
  {
    input:  messages.sum(:input_tokens),
    output: messages.sum(:output_tokens),
  }
end
```

`sum` already coalesces nils to 0. Two queries; the chat header is called once per request.

Cached / cache-creation sub-totals stay in the database; if admin tooling later wants them, add a separate method then.

### `Chat#context_tokens`

The maximum `input_tokens` value across the last 10 assistant messages in the chat:

```ruby
def context_tokens
  messages.where(role: "assistant")
          .reorder(created_at: :desc)
          .limit(10)
          .maximum(:input_tokens) || 0
end
```

Why max-of-last-10 and not last-turn? In a multi-agent chat, different agents have different system prompts, memories, and tool schemas. A single agent's last turn isn't representative of context pressure across the conversation. Taking the max across recent assistant turns captures worst-case context pressure — exactly the signal that should drive long-conversation warnings.

The provider's own `input_tokens` count includes system prompt, replayed transcript, replayed reasoning (when the provider replays it), and tool schemas. That is correct for "is this conversation getting too big for the context window," which is the question the warning answers. The requirements doc's "transcript-only" framing is an idealization that would actually understate context pressure: a chat with a 30k-token system prompt and tool catalogue is in real context-window trouble even with a short transcript, and the user needs to see that. No tokenizer dependency.

Header label stays "Context: Nk" — that's the right user-facing word for the worst-case input size on this chat's recent turns.

### `Chat#reasoning_tokens`

Chat-level reasoning usage, available alongside `cost_tokens` for admin/debug/API consumers:

```ruby
def reasoning_tokens
  messages.sum(:thinking_tokens)
end
```

This satisfies requirement 9C ("Reasoning usage must be available as its own metric"). It is **not** shown in the chat header — the header shows only Context and Cost (per the user's clarification). It is exposed via `Chat#json_attributes` for the audit log, future cost-reporting views, and API consumers. One method, no UI.

### JSON shape and thresholds

`Chat#json_attributes` replaces `:total_tokens` with `:context_tokens`, `:cost_tokens`, and `:reasoning_tokens`. The sidebar JSON exclusion list (`Chat.json_attrs_for`, `app/models/chat.rb:51`) drops `:total_tokens` and adds `:cost_tokens` and `:reasoning_tokens` (sidebar still excludes them all; only the chat page renders Context and Cost).

Long-conversation thresholds (`100_000` / `150_000` / `200_000`) apply to `context_tokens`.

## Callers of `total_tokens` to update

Confirmed by grep:

- `app/models/chat.rb:23` — `json_attributes` line. Replace `:total_tokens` with `:context_tokens, :cost_tokens, :reasoning_tokens`.
- `app/models/chat.rb:51` — `Chat.json_attrs_for` sidebar exclusion. Replace `:total_tokens` with `:cost_tokens, :reasoning_tokens` (sidebar omits all three).
- `app/models/chat.rb:583` — the method itself. Delete.
- `app/frontend/lib/components/chat/ChatHeader.svelte` — `totalTokens` prop. Replace with `contextTokens` + `costTokens`.
- `app/frontend/pages/chats/show.svelte` — props passed into `ChatHeader`.
- Any test referencing `chat.total_tokens` — update to `context_tokens` / `cost_tokens`.

## UI

### `ChatHeader.svelte`

```svelte
<span class="ml-2 text-xs">
  Context: {formatTokenCount(contextTokens)} · Cost: {formatTokenCount(costTokens.input)} in / {formatTokenCount(costTokens.output)} out
</span>
```

Warning thresholds read `contextTokens`. Badge copy ("Long conversation" / "Very long" / "Extremely long") unchanged.

### `MessageBubble.svelte`

```svelte
{#if message.reasoning_skip_reason}
  <span title={reasoningSkipTooltip(message.reasoning_skip_reason)}
        class="text-muted-foreground inline-flex items-center">
    <LightbulbFilament size={14} />
  </span>
{/if}
```

`chat-utils.js`:

```js
const REASONING_SKIP_LABELS = {
  legacy_no_signature:        "Thinking unavailable: this turn was created before signed thinking blocks were stored.",
  tool_continuity_missing:    "Thinking degraded: an earlier tool call is missing continuity metadata.",
  provider_unsupported:       "Thinking unavailable for this turn.",
  anthropic_key_unavailable:  "Thinking unavailable: Anthropic API key not configured.",
};
export function reasoningSkipTooltip(reason) {
  return REASONING_SKIP_LABELS[reason] || "Thinking was unavailable for this message.";
}
```

## Forking

`Chat#fork_with_title!` (`app/models/chat.rb:710`) currently copies content, role, user_id, agent_id, input_tokens, output_tokens, tools_used. Add `replay_payload`, `cached_tokens`, `cache_creation_tokens`, `reasoning_skip_reason`, `thinking_text`, `thinking_tokens`. Also copy `tool_calls` rows (with `replay_payload`) so Gemini continuity survives the fork.

This extension is in scope: without it, every forked chat would silently reintroduce exactly the bug this spec exists to fix — turn 1 has thinking, turn 2 loses it because the fork dropped the signature. Fork is a copy operation, and a copy that drops half the conversational state isn't a copy.

## Testing

All Ruby tests use VCR. No mocks. `require "support/vcr_setup"`, cassettes under `test/vcr_cassettes/`.

### `test/models/message/record_provider_response_test.rb`

- Anthropic raw with thinking signature → `replay_payload["thinking"]["signature"]` populated.
- OpenRouter raw with `reasoning_details` → `replay_payload["reasoning_details"]` populated.
- Gemini raw with `thoughtSignature` on a tool call → `tool_calls.replay_payload` populated.
- `cached_tokens` / `cache_creation_tokens` populated from each provider's raw shape.
- `model_id_string` reflects the resolved provider model id from the response (verified against direct-Anthropic and OpenRouter cassettes).
- Empty Gemini `SAFETY` response: streaming concern composes the safety string before calling `record_provider_response!`; persisted `content` is the safety string.

`RubyLLM::Message` instances built from fixture JSON pulled from real cassettes. No mocks.

### `test/models/message/replay_test.rb`

- Anthropic, same agent, signed → returns thinking block.
- Anthropic, same agent, legacy unsigned → returns assistant text only; `inferred_skip_reason` returns `legacy_no_signature`.
- Anthropic, other agent → user-shaped with `[Name]:` prefix.
- OpenRouter, same agent, no `replay_payload` → assistant text only, no skip reason.
- OpenRouter, same agent, with `reasoning_details` → includes them.
- Gemini, same agent, tool call with signature → tool call serialized with signature.
- Gemini, same agent, tool call without signature → tool call serialized without `thought_signature`; no fabrication.
- A chat with 10 legacy unsigned Anthropic turns: `Chat#build_context_for_agent` returns 10 user/assistant entries with no thinking blocks; the new turn has thinking enabled.

### `test/models/chat_test.rb`

- `context_tokens` returns the maximum `input_tokens` across the last 10 assistant messages.
- `context_tokens` returns 0 when no assistant turns exist.
- `cost_tokens` returns `{ input:, output: }` summing across messages, treating nils as zero.
- `reasoning_tokens` sums `thinking_tokens` across messages, treating nils as zero.
- `Chat` no longer responds to `:thinking_compatible_for?` or `:total_tokens`.

### Integration cassettes

Six cassettes, one per scenario. Each asserts the persisted shape on the resulting `Message` row.

- `anthropic_thinking_two_turn` — thinking persists on turn 1; turn 2 succeeds with thinking enabled and the prior signature replayed.
- `anthropic_thinking_with_other_agent` — agent A (thinking) + agent B (no thinking model) + agent A again. B's message replays as user-shaped; A's thinking is not disabled by B's existence.
- `openrouter_thinking_no_signature` — Grok or DeepSeek two-turn; `reasoning_details` persisted and replayed; no `legacy_no_signature` flag.
- `gemini_tool_call_continuity` — Gemini tool turn + follow-up; `tool_calls.replay_payload` carries `thought_signature`; the second outbound request includes it.
- `gemini_legacy_tool_continuity_missing` — chat with a prior agent tool call whose `tool_calls` row has no `replay_payload` (or has `replay_payload` without a `thought_signature`). Verifies: the replay for the next turn omits the missing signature for that tool call (no fabrication); `reasoning_skip_reason: "tool_continuity_missing"` is stamped on the new assistant message; no provider-side error; behavior is deterministic across retries.
- `legacy_anthropic_no_signature_recovers` — fixture-seeded chat with an unsigned legacy Anthropic turn + new user turn. Legacy turn replays without thinking; new turn carries thinking + signature; `inferred_skip_reason` returns `legacy_no_signature` for the legacy turn.

### `test/integration/chat_token_display_test.rb`

- After `anthropic_thinking_two_turn`: `context_tokens == max(input_tokens of last 10 assistant turns)`.
- `cost_tokens[:input]` and `cost_tokens[:output]` are per-turn sums.
- `reasoning_tokens` is the per-turn sum of `thinking_tokens`.
- Chat JSON includes `context_tokens`, `cost_tokens`, and `reasoning_tokens`, not `total_tokens`.

## Acceptance Criteria → Tests

| # | Criterion | Test |
| - | --------- | ---- |
| 1 | Two-turn Anthropic conversation keeps thinking enabled on turn 2 | `manual_agent_response_job_test.rb` — `anthropic_thinking_two_turn` |
| 2 | Multi-agent: another agent's lack of metadata doesn't disable agent A's thinking | `manual_agent_response_job_test.rb` — `anthropic_thinking_with_other_agent` |
| 3 | New assistant messages persist signatures and reasoning token metadata | `record_provider_response_test.rb` and integration cassettes |
| 4 | Tool calls persist when continuity needs them (Gemini) | `manual_agent_response_job_test.rb` — `gemini_tool_call_continuity` and `gemini_legacy_tool_continuity_missing` |
| 5 | Legacy conversations no longer fail through silent reasoning drop | `replay_test.rb` legacy cases + `legacy_anthropic_no_signature_recovers` + `gemini_legacy_tool_continuity_missing` |
| 6 | Primary chat header label = active context, not lifetime billing | `chat_token_display_test.rb` |
| 7 | Lifetime usage available separately for reporting | `chat_test.rb#cost_tokens` |
| 8 | Reasoning tokens stored separately and exposed as their own metric | `chat_test.rb#reasoning_tokens` + `record_provider_response_test.rb` |
| 9 | Multi-agent and single-agent paths share persistence semantics | All three job tests assert identical column shapes via `Message#record_provider_response!` |

## Files Touched

New:

- `db/migrate/20260427120000_upgrade_conversation_replay.rb`
- `test/models/message/record_provider_response_test.rb`
- `test/models/message/replay_test.rb`
- `test/integration/chat_token_display_test.rb`
- `test/vcr_cassettes/anthropic_thinking_two_turn/...`
- `test/vcr_cassettes/anthropic_thinking_with_other_agent/...`
- `test/vcr_cassettes/openrouter_thinking_no_signature/...`
- `test/vcr_cassettes/gemini_tool_call_continuity/...`
- `test/vcr_cassettes/gemini_legacy_tool_continuity_missing/...`
- `test/vcr_cassettes/legacy_anthropic_no_signature_recovers/...`

Modified:

- `app/models/message.rb` — adds `record_provider_response!`, `sync_tool_calls_from`, `replay_for`, `gemini_tool_call_replay`, `reasoning_skip_reason` reader, `thinking_signature` reader.
- `app/models/chat.rb` — drops `thinking_compatible_for?` and `total_tokens`. Adds `context_tokens`, `cost_tokens`, `reasoning_tokens`. `build_context_for_agent` takes `provider:`. `format_message_for_context` delegates to `Message#replay_for`. `fork_with_title!` copies new columns and tool calls.
- `app/jobs/concerns/streams_ai_response.rb` — `finalize_message!` composes content (including the empty-response/SAFETY fallback) then calls `record_provider_response!`.
- `app/jobs/manual_agent_response_job.rb` — drops `thinking_compatible_for?`. Sets `reasoning_skip_reason` (`tool_continuity_missing` for Gemini turns with missing prior tool signatures). Passes `provider:` into `build_context_for_agent`.
- `app/jobs/all_agents_response_job.rb` — same.
- `app/jobs/ai_response_job.rb` — inherits the consolidated `finalize_message!`. Passes `provider:` into context-building.
- `app/frontend/lib/components/chat/ChatHeader.svelte` — Context / Cost copy.
- `app/frontend/lib/components/chat/MessageBubble.svelte` — reasoning-skip icon.
- `app/frontend/lib/chat-utils.js` — `reasoningSkipTooltip` (includes `tool_continuity_missing`).
- `app/frontend/pages/chats/show.svelte` — passes new props.

## Out of Scope

- Agent memory / summary / whiteboard changes.
- RubyLLM replacement.
- Tokenizer dependencies.
- Backfilling provider signatures we don't have.
- Admin/debug UI beyond the per-message reasoning-skip indicator.
- Streaming UX changes.
