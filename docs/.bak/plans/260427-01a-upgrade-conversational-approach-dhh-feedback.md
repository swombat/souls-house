# DHH-Style Review: Upgrade Conversational Approach

**Spec under review:** `docs/plans/260427-01a-upgrade-conversational-approach.md`
**Date:** 2026-04-27

---

## Top-line verdict

**Not ship-ready.** The diagnosis is correct and the schema choices are mostly sound, but the spec invents three service-objects-in-disguise (`Message::ProviderPayload`, `Message::Replay`, `Message::ToolCallSync`) where there should be plain methods on `Message` plus a small `case provider` switch. The naming is technical-sounding (`absorb!`) where Rails-flavored direct names exist. The fancy abstractions need to be deleted and re-folded back into the model before this gets implemented — otherwise we're just relocating the framework-fighting from RubyLLM into our own app code.

---

## Strengths (preserve these in the next iteration)

- **Diagnosis is right.** The "global thinking compatibility gate" being wrong is correctly identified. The per-turn fallback policy lifted from the requirements clarifications is correctly implemented at the conceptual level.
- **Schema is mostly disciplined.** A single `replay_payload jsonb` column instead of a per-provider column zoo is the right call. The `cached_tokens` / `cache_creation_tokens` split is appropriately additive.
- **No backfill, no fabrication.** Honest about legacy data: legacy turns degrade explicitly per-turn, signatures are never invented. This is correct.
- **`context_tokens` algorithm is honest.** Using "the most recent assistant message's `input_tokens`" as the truth source is the right pragmatic call. No tokenizer dependency. Good.
- **Cassette set is rightly sized.** Five VCR cassettes covering the real provider matrix is appropriate, not over-tested.
- **Deleting `Chat#thinking_compatible_for?` outright** rather than patching it. Right move.

---

## Issues, ordered by severity

### 1. `Message::ProviderPayload`, `Message::Replay`, and `Message::ToolCallSync` are service objects with a Russian-doll namespace

This is the headline problem. Three new classes, each with one job, wrapped in the `Message::` namespace to disguise that they're service objects. The spec even acknowledges this and tries to pre-empt the criticism ("It is a Plain Old Ruby Object that lives under the `Message` namespace — not a service object — and exists purely as a translator..."). That's exactly what a service object is. A namespace doesn't launder it.

**What's wrong, per the Rails Way (architecture.md):**

> "No unnecessary abstractions - Avoid service objects and premature optimization"
> "BAD - Service object (avoid these): `class RegistrationService; def execute ... end end`"

`Message::ProviderPayload.new(ruby_llm_message).replay_payload` is `RegistrationService.new(params).execute` with extra steps. Instantiating an object whose only purpose is to immediately read attributes off it is the textbook smell.

**What it should be:**

Methods on `Message`. The translation from `RubyLLM::Message` to our columns is a *Message responsibility*. Put it there.

```ruby
class Message
  def self.from_provider_response(ruby_llm_message, into:, fallback_content: nil, tool_names: [])
    into.update!(
      content:               extract_content(ruby_llm_message, fallback: fallback_content) || into.content,
      thinking_text:         extract_thinking(ruby_llm_message),
      thinking_tokens:       ruby_llm_message.thinking_tokens,
      input_tokens:          ruby_llm_message.input_tokens,
      output_tokens:         ruby_llm_message.output_tokens,
      cached_tokens:         extract_cached_tokens(ruby_llm_message),
      cache_creation_tokens: extract_cache_creation_tokens(ruby_llm_message),
      model_id_string:       ruby_llm_message.model_id,
      provider_model_id:     extract_provider_model_id(ruby_llm_message),
      replay_payload:        build_replay_payload(ruby_llm_message),
      tools_used:            tool_names.uniq.presence || into.tools_used,
    )
    into.sync_tool_calls_from(ruby_llm_message)
    into
  end

  def replay_for(provider, current_agent:)
    return user_shaped_replay if agent_id != current_agent.id
    case provider
    when :anthropic            then anthropic_replay
    when :gemini               then gemini_replay
    when :openrouter, :openai, :xai then openrouter_style_replay
    end
  end

  private

  def anthropic_replay
    sig = replay_payload&.dig("anthropic", "thinking", "signature")
    return assistant_text_only if thinking_text.present? && sig.blank? && stamp_legacy_skip!
    { role: :assistant, content: content }.merge(
      sig.present? ? { thinking: thinking_text, thinking_signature: sig } : {}
    )
  end

  # ...etc
end
```

That's it. Three classes deleted. The "switch on provider" lives where it belongs — on the model that owns the data. If a provider's logic grows past 30 lines, *then* extract a private method per provider. Not before.

The tool-call sync is one method:

```ruby
def sync_tool_calls_from(ruby_llm_message)
  Array(ruby_llm_message.tool_calls).each do |tc|
    tool_calls.find_or_create_by!(tool_call_id: tc.id) do |row|
      row.name           = tc.name
      row.arguments      = tc.arguments
      row.replay_payload = gemini_thought_signature(tc)
    end
  end
end
```

If the tool-call sync logic ever needs to be shared with another model, *then* extract a concern. Not today.

### 2. `Message#absorb!` is the wrong name

`absorb!` is technical and vague. What's being absorbed? Why would I, a Rails programmer six months from now, search for `absorb!` to find this code? The verb should describe the domain action.

**Suggestions, in order of preference:**

1. `Message.from_provider_response(ruby_llm_message, into: @ai_message, ...)` — a class-level factory-ish action; reads as "build/update a Message from a provider response". This is my recommendation.
2. `@ai_message.record_response!(ruby_llm_message, ...)` — fine; verb-first, clear domain meaning.
3. `@ai_message.update_from_response!(ruby_llm_message, ...)` — boring but unambiguous.

`absorb!` reads like the model is doing something opaque to a foreign object. Don't ship that name.

The spec's argument that `absorb!` does too much for a single `update!` is correct in spirit but the answer isn't to invent a verb — it's to put a method-level name on the *intent*: "record this provider response onto this message".

### 3. `provider_for(current_agent)` symmetry is hand-waved — fix this in the spec

Buried in "Open Risks" is:

> "The context-builder and the response job MUST agree on which provider is used. The job calls `llm_provider_for(agent.model_id, ...)`. The same call should drive `format_message_for_context`. Pass `provider:` explicitly into `chat.build_context_for_agent`."

This is not a risk note, it's a requirement, and the spec leaves it as a TODO. The fix is one line in the spec: `chat.build_context_for_agent(agent, provider:, thinking_enabled:, ...)` and the job passes the same `provider_config[:provider]` it uses for the LLM call. Specify it. Don't leave the asymmetry to be discovered at implementation time.

### 4. Stamping `reasoning_skip_reason` during a read is hidden in the risk section, not designed

The spec proposes stamping `reasoning_skip_reason = "legacy_no_signature"` via `update_column` *during context-building for replay*. That's a write inside what every Rails developer expects to be a read path. It will surprise people. It will fire callbacks (or skip them, depending on which method you choose, which itself is a footgun).

**What to do instead:** drop the persistence. Compute `reasoning_skip_reason` at read time when no value is set:

```ruby
def reasoning_skip_reason
  self[:reasoning_skip_reason] || inferred_skip_reason
end

private

def inferred_skip_reason
  return nil unless role == "assistant"
  return "legacy_no_signature" if thinking_text.present? &&
                                  replay_payload.blank? &&
                                  thinking_signature.blank?
  nil
end
```

This eliminates the read-during-write hack, eliminates the worry about read replicas, eliminates the worry about firing callbacks at unexpected times. The UI gets the correct label, no migration needed, and the column only carries explicit (current-turn) skip reasons. The risk note disappears.

The spec says "recommend the persisted version because it's diagnosable." Diagnosable how? You can compute the same answer from the existing columns. There is no diagnosis benefit. Drop it.

### 5. `provider_model_id` column duplicates `model_id_string` in 90% of cases — justify it harder or drop it

`messages.model_id_string` already stores the routed model. The spec says `provider_model_id` is "exact provider model used for this turn (e.g. `claude-opus-4-5-20251101`). Distinct from `model_id_string` (which is the OpenRouter-shaped routing key)."

That's true *only* when the request was routed through OpenRouter and ended up at a specific Anthropic model. For direct API calls (which is the path used for thinking, per the codebase's `requires_direct_api_for_thinking?` logic), the two are likely the same string already. For OpenRouter calls, OpenRouter returns the resolved model ID which RubyLLM puts into `model_id`, and `model_id_string` already gets that.

**Action:** before adding a column, prove (in the spec) one concrete case where `provider_model_id` differs from `ruby_llm_message.model_id` (which the spec writes to `model_id_string`). If there isn't one, drop the column. If there is one, document it inline in the schema migration. New columns must pull their weight.

I suspect the answer is that the column is unnecessary and the spec author was thinking about the `Chat::MODELS` `provider_model_id:` config key (which is a config concern, not a per-message storage concern). They are not the same thing.

### 6. `reasoning_skip_reason` enum has too many values for what the UI does with them

Five enum values, all collapsing into "thinking unavailable for this turn" with slight tooltip variations. The UI, per the spec, shows one icon and a tooltip with one of five sentences.

Three of these five values (`provider_no_replayable_reasoning`, `tool_call_continuity_missing`, `model_lacks_thinking_support`) are essentially the same user-facing message — "this provider/model didn't support replayable reasoning here." Only `legacy_no_signature` and `anthropic_key_unavailable` are genuinely distinct.

**Action:** collapse to three values:

| Value                       | Meaning                                                                  |
| --------------------------- | ------------------------------------------------------------------------ |
| `legacy_no_signature`       | Pre-upgrade Anthropic message with thinking text but no signature.       |
| `provider_unsupported`      | Model/provider doesn't support replayable reasoning for this turn.       |
| `anthropic_key_unavailable` | Anthropic direct API needed but key isn't configured.                    |

If the team later finds it needs to distinguish "tool continuity missing" from "no reasoning details", add the value then. Don't pre-build vocabulary you don't use. Five enum values × five tooltip strings × five test paths is bloat that delivers no user value.

### 7. The `Chat#cost_tokens` method returns five keys; the UI uses two

```ruby
{ input:, output:, reasoning:, cached:, cache_creation: }
```

The chat header renders `Cost: in {input} / out {output}`. The other three keys are spec-future "may surface in admin/debug UI." Build that when you build the admin UI.

For now: `cost_tokens` returns `{ input:, output: }`. Two SUMs, two keys. If/when admin needs reasoning/cache breakdown, add it then. Right now it's three columns of dead JSON in every chat header response.

### 8. `Chat#total_tokens` should be deleted, but the spec says callers "include `Chat#json_attributes`" — verify it's actually used in only the places stated

The spec says "Currently used in `Chat#json_attributes` and the chat header." Confirmed in `app/models/chat.rb:23` (`json_attributes ... :total_tokens, ...`). But the spec should explicitly enumerate every caller in a grep before saying "remove it; replace with the new pair." Tests, sidebar JSON serializer overrides (line 51), Svelte components — all need verification. As written, this is a one-line claim that papers over real find-replace work.

**Action in spec:** add an explicit "callers of `Chat#total_tokens` to update" list, found by grepping the codebase, including frontend `totalTokens` references. Otherwise this will leak.

### 9. The Svelte changes are passable but the chat header copy is dressed up

The proposed:

```
Context: 18.4k · Cost: in 12.1k / out 4.2k
```

Compared to the requirement language:

> "Context: 18.4k tokens"
> "Lifetime usage: 132k tokens"

The clarification says "Cost" is the chosen label (overriding "Lifetime usage"). Fine. But the spec's `· Cost: in 12.1k / out 4.2k` reads cluttered. Two suggestions:

1. Trust the user to know what "in/out" means without labeling: `Context: 18.4k · Cost: 12.1k in / 4.2k out`. Or:
2. Drop "in" / "out" entirely and just show total cost, with a hover/click for breakdown: `Context: 18.4k · Cost: 16.3k`.

Either reads more cleanly than `in 12.1k / out 4.2k`. The spec is putting four numbers in a chat header where two would do. DHH would cut.

This is a minor copy issue; not blocking. But while you're touching it, simplify.

### 10. The `Message#thinking_signature` reader becoming a `dig` proxy is a dual-source-of-truth landmine

The spec proposes:

```ruby
def thinking_signature
  replay_payload.dig("anthropic", "thinking", "signature") || self[:thinking_signature]
end
```

This means there are now two storage locations for the same value, and reads check both. It's labeled as backwards-compatibility and "out of scope" to clean up. That's how dual-write/dual-read code stays for years.

**Better:** the migration should also `update_all` to copy the existing `thinking_signature` column values into `replay_payload['anthropic']['thinking']['signature']` for messages where it's set. Then the reader only reads from `replay_payload`. The legacy column gets dropped in a follow-up migration in 2 weeks.

Yes, this is "backfilling." But it's not backfilling *signatures we don't have* — it's relocating signatures we *do* have, into the new structure, so the reader has one source of truth. The spec's "no backfill" rule is about not fabricating data; it doesn't preclude moving existing data into a new column.

If even that feels like too much, then at minimum the spec must specify: which writers update which column? If `Message.from_provider_response` writes only `replay_payload`, what writes `thinking_signature` going forward? If nothing does, the dual-read reader is dead code on the second branch and should just read `replay_payload`. The current spec leaves this ambiguous.

### 11. Test plan: `legacy_replay_test.rb` and `replay_test.rb` overlap

The spec adds:

- `test/models/message/replay_test.rb` (six cases)
- `test/models/message/legacy_replay_test.rb` (two cases, both already covered by `replay_test.rb` case 2)

Merge them. One `replay_test.rb` covering all six provider-shape cases plus the two legacy regressions is one file, ~80 lines, easy to read. Splitting "legacy" out is bureaucratic.

Also: the "Test that thousands of historical messages don't cause a global thinking disable" assertion proposes "a chat with 10 such legacy messages still allows a new Anthropic turn to enable thinking." That's a unit test of a deleted method (`thinking_compatible_for?` is gone). Restate it as: "a chat with 10 legacy messages, when context-built for Anthropic, produces 10 user/assistant entries with no thinking blocks plus the new turn enables thinking." That's a `Chat#build_context_for_agent` test.

### 12. `acceptance criterion #10` is an empty cell

The acceptance table row 10:

> "RubyLLM stays in place, not the source of ambiguity / Implicit — `Message#absorb!` is the single owner of column writes; `to_llm` still routes through RubyLLM"

"Implicit" isn't an acceptance test. Either delete the row (the boundary is implicit in the implementation) or specify a real assertion (e.g., "no controller or job writes to `messages.replay_payload` directly; only `Message.from_provider_response` does"). As written it's filler.

### 13. The empty-response handling moves from `finalize_message!` into a "private method" without specifying where

The spec says:

> "The empty-response handling (Gemini SAFETY etc.) stays as a private method."

In the concern? On the message? The current Gemini SAFETY logic sniffs `ruby_llm_message.raw` — that's a Message-from-provider-response concern. Put it on Message:

```ruby
def self.fallback_content_for_empty_response(ruby_llm_message)
  return nil unless ruby_llm_message.content.blank? && ruby_llm_message.output_tokens.to_i == 0
  raw = ruby_llm_message.raw.is_a?(Hash) ? ruby_llm_message.raw : {}
  reason = raw.dig("candidates", 0, "finishReason") || raw.dig("choices", 0, "finish_reason")
  case reason
  when "SAFETY" then "_The AI was unable to respond due to content safety filters..._"
  when nil      then "_The AI returned an empty response..._"
  else               "_The AI was unable to complete its response (reason: #{reason})._"
  end
end
```

Called inline from `from_provider_response`. The concern doesn't need to know about Gemini SAFETY semantics.

### 14. The spec doesn't address `AllAgentsResponseJob` directly even though it's in scope

The spec lists `AllAgentsResponseJob` in "Files Touched" with the same one-line treatment as `ManualAgentResponseJob`, but never inspects whether they really do share the same shape. `AllAgentsResponseJob` runs multiple agents in sequence — does each agent's turn go through the same `from_provider_response` path? Probably yes, but the spec should explicitly verify that the inner loop in `AllAgentsResponseJob` shares the streaming state and finalize lifecycle. One paragraph, not a TODO at implementation time.

### 15. Minor: the Anthropic key precheck duplication

The spec keeps the "Anthropic API key precheck" but also has `anthropic_key_unavailable` as a `reasoning_skip_reason`. Where does each fire? The current code does the precheck and `broadcast_error` then `return`s without persisting a message. The new flow with skip reasons suggests we'd persist a message with the skip reason instead. Pick one path. If we keep `broadcast_error + return`, drop `anthropic_key_unavailable` from the enum. If we keep the enum, the job needs to write a message with the skip reason rather than bailing. The spec lets both exist.

---

## Summary of concrete edits to the spec

1. **Delete** `app/models/message/provider_payload.rb`, `app/models/message/replay.rb`, `app/models/message/tool_call_sync.rb` from "New files." Replace with private methods on `Message`.
2. **Rename** `Message#absorb!` to `Message.from_provider_response(ruby_llm_message, into:, ...)` (class method), or `Message#record_response!(ruby_llm_message, ...)`.
3. **Delete** the `update_column(:reasoning_skip_reason, ...)` write-during-read pattern. Compute legacy skip reasons in a reader: `def reasoning_skip_reason; self[:reasoning_skip_reason] || inferred_skip_reason; end`.
4. **Justify or drop** `provider_model_id` column. If kept, document the concrete divergence case in the migration.
5. **Collapse** `reasoning_skip_reason` enum from five values to three.
6. **Reduce** `Chat#cost_tokens` return value from five keys to two (`input`, `output`).
7. **Move** the `provider:` parameter-passing into `Chat#build_context_for_agent` signature explicitly. Not a "risk note" — a designed parameter.
8. **Backfill** existing `thinking_signature` column values into `replay_payload['anthropic']` in the migration so `Message#thinking_signature` reads from one source. Drop the dual-source reader.
9. **Merge** `legacy_replay_test.rb` into `replay_test.rb`.
10. **Specify** every caller of `total_tokens` (Ruby, Svelte, JSON serializers) explicitly in the spec.
11. **Decide** between `broadcast_error + return` and `persist message with skip reason` for the Anthropic-key-missing path. Don't keep both.
12. **Inspect and document** that `AllAgentsResponseJob`'s per-agent loop genuinely uses the same persistence contract.
13. **Delete or specify** acceptance criterion 10 (the "Implicit" row).
14. **Move** the Gemini SAFETY empty-response handling onto `Message` as a class method.
15. **Trim** the chat header copy: pick one of the two cleaner formats above.

Once those edits are made, this spec is ready to implement. The schema is right, the diagnosis is right, the legacy fallback policy is right. The implementation shape just needs to follow the Rails Way as practiced in this codebase: methods on models, not classes-pretending-to-be-modules.
