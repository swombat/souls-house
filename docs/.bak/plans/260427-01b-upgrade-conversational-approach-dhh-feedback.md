# DHH-Style Review (Round 2): Upgrade Conversational Approach

**Spec under review:** `docs/plans/260427-01b-upgrade-conversational-approach.md`
**Previous round:** `docs/plans/260427-01a-upgrade-conversational-approach-dhh-feedback.md`
**Date:** 2026-04-27

---

## Verdict

**Ship-ready after one more pass — small, surgical edits only.** The bones are correct now; what remains is mostly naming, an awkward `into:` parameter, and one method that doesn't belong on `Message`.

---

## What 01b got right

- The three pseudo-service-objects are gone. `Message::ProviderPayload`, `Message::Replay`, and `Message::ToolCallSync` are now private class methods and one instance method on `Message`. Good.
- `reasoning_skip_reason` is now read-time inferred for legacy data via a single reader composition. No more `update_column` during context building. The risk note that justified the hack is correctly deleted.
- Enum collapsed to three values. UI labels match.
- `cost_tokens` returns two keys.
- `provider_model_id` column is gone, with a one-paragraph justification right where it matters.
- `thinking_signature` column is migrated into `replay_payload` and dropped. One source of truth, no dual-read landmine.
- `provider:` is an explicit parameter on `build_context_for_agent` and `format_message_for_context`. The "open risk" became a designed contract.
- The Anthropic-key-missing branch now picks one path (persist a stub message with skip reason) instead of leaving both alive.
- `AllAgentsResponseJob` is explicitly addressed in one sentence: "per-agent loop streams into a fresh `@ai_message` per agent and calls `finalize_message!` per agent — same contract."
- Total of ~120 fewer lines than 01a, and it reads faster. The Diagnosis section is two short paragraphs that name files and line numbers. That's the right register.

---

## Remaining issues, ordered by severity

### 1. `Message.from_provider_response(rlm, into: @ai_message, ...)` — the `into:` parameter is the smell

A class method that takes the receiver as a keyword argument is a code smell. The whole point of OO is that `into` *is* `self`. Right now the call site reads:

```ruby
Message.from_provider_response(
  ruby_llm_message,
  into:             @ai_message,
  fallback_content: ...,
  tool_names:       @tools_used,
)
```

That reads like a service object that happens to live in the `Message` class. Make it an instance method:

```ruby
@ai_message.record_provider_response!(ruby_llm_message,
  fallback_content: @content_accumulated.presence,
  tool_names:       @tools_used,
)
```

Or even better, drop `fallback_content` from the public surface (the streaming concern already buffered the content; passing it back into the model at finalize time is a leaky abstraction). The concern can do:

```ruby
@ai_message.content = @content_accumulated.presence || @ai_message.content if @ai_message.content.blank?
@ai_message.record_provider_response!(ruby_llm_message, tool_names: @tools_used)
```

Then `record_provider_response!` only needs `tool_names:`.

This is the single biggest remaining issue. The `into:` parameter is round-1's service object wearing a slightly better disguise. Make the receiver the receiver.

**Specific edit:** rename `Message.from_provider_response(rlm, into:, ...)` → `Message#record_provider_response!(rlm, ...)`, instance method, no `into:`.

### 2. The empty-response Gemini SAFETY fallback is in the wrong place

`Message.fallback_content_for_empty_response` is a class method on `Message` that pokes into `RubyLLM::Message#raw` to extract a `finishReason` and synthesize a user-visible apology string ("_The AI was unable to respond due to content safety filters._").

That's not a Message responsibility. Message stores the content. Whoever decided what the content should be when the provider failed is a *job-level* concern. The streaming concern already has the right context (it knows the agent, it knows the response state). It should compose the fallback string and pass it as content.

The previous round's feedback (item 13) said "put it on Message" — I want to retract that. Looking at this again with the cleaner shape: the apology copy is UX, not data. Put it back in the concern as a private method (`empty_response_fallback(rlm)`), call it before the `record_provider_response!` call, and feed the result in as part of content composition.

This also removes the only reason `Message` needs to know about `RubyLLM::Message#raw` shapes for *content* — it still legitimately knows about them for `replay_payload` and token extraction, which are persistence concerns.

**Specific edit:** move `fallback_content_for_empty_response` from `Message` to `StreamsAiResponse` as a private method. The concern composes content, the model persists it.

### 3. The `case provider` switch is fine — verify, don't extract

You correctly resisted polymorphism. Three providers, ~3 lines per branch in `build_replay_payload` and ~5 lines per branch in `replay_for`. Switch is right. If a fourth provider lands and the branches grow past ~10 lines each, *then* extract `Message::AnthropicReplay`, `Message::GeminiReplay`, etc. Not before.

No edit needed. Just naming the choice so it doesn't get second-guessed in implementation.

### 4. Read-time `inferred_skip_reason` — clean as written, but document the input

The reader currently looks at `thinking_text.present? && replay_payload.blank?` and infers `legacy_no_signature`. That's fine and self-contained. It does NOT pull from current agent settings (which would be the surprising case round 1 worried about). Good.

One small concern: `inferred_skip_reason` returns `nil` for `role != "assistant"`, but this method is called as part of `json_attributes` for every message. Adding `where: "reasoning_skip_reason IS NOT NULL"` to the migration index helps DB queries but not Ruby-level reads. This is fine — the method is cheap. No edit needed; just confirming it's not secretly expensive.

### 5. `private` declared above `def self.extract_content` does nothing

```ruby
private

def self.extract_content(rlm, fallback:)
  ...
end
```

In Ruby, `private` doesn't apply to `def self.foo` definitions. Those methods are public class methods. To make them private use `private_class_method :extract_content` or wrap in `class << self; private; def extract_content...`.

This is a small Ruby-isn't-Java gotcha. The spec's example code is technically wrong. It works (the methods aren't called externally, so no test fails), but a Rails-quality codebase shouldn't ship `private` keywords that have no effect.

**Specific edit:** in the spec's code sample, either change the helpers to instance methods (preferred — they don't need to be on the class), or wrap them properly:

```ruby
class << self
  private

  def extract_content(rlm, fallback:) ... end
  def extract_cached_tokens(rlm) ... end
  # etc
end
```

The cleanest version: make them all instance methods called from within `record_provider_response!`. That naturally gives you private visibility, no class-method gymnastics.

### 6. `extract_content`'s signature passes `fallback:` but the body uses `fallback_content_for_empty_response(rlm)` and then `fallback.presence`

```ruby
def self.extract_content(rlm, fallback:)
  text = strip_leading_timestamp(rlm.content.to_s).presence
  text || fallback_content_for_empty_response(rlm) || fallback.presence
end
```

If item 2 is taken (move SAFETY handling to the concern), this collapses to:

```ruby
def extract_content(rlm)
  strip_leading_timestamp(rlm.content.to_s).presence
end
```

And the concern handles the fallback chain:

```ruby
content = Message.strip_leading_timestamp(rlm.content.to_s).presence ||
          empty_response_fallback(rlm) ||
          @content_accumulated.presence ||
          @ai_message.reload.content
```

Three responsibilities, three callers. Currently they're tangled in one method that takes a `fallback:` parameter the caller may or may not have populated.

### 7. `provider_for(current_agent)` in `format_message_for_context` is now a parameter — but the spec still references it

The 01a spec used `provider_for(current_agent)` as a method call. 01b makes `provider:` a parameter to `format_message_for_context`. The spec correctly shows the new signature, but in passing references the old call shape. Re-read this paragraph:

> "`ManualAgentResponseJob` and `AllAgentsResponseJob` resolve the provider via `llm_provider_for(agent.model_id, thinking_enabled: @use_thinking)` and pass `provider:` into `build_context_for_agent`. `AiResponseJob` passes the provider it resolved through `Chat#to_llm`."

That's correct. Nothing to fix in the spec text. Just flagging that the implementer needs to verify `AiResponseJob` actually has access to the resolved provider symbol at the right point — `Chat#to_llm` lives on the chat, but the provider resolution is in `ResolvesProvider`. One line of plumbing in `AiResponseJob` to read it back out before the context is built. Not a spec bug; a heads-up for implementation.

### 8. `cost_tokens` uses `pick` with two `Arel.sql` SUMs — fine, but `pluck` is nicer here

```ruby
def cost_tokens
  result = messages.unscope(:order).pick(
    Arel.sql("COALESCE(SUM(input_tokens), 0)"),
    Arel.sql("COALESCE(SUM(output_tokens), 0)"),
  )
  { input: result[0], output: result[1] }
end
```

This works. A slightly more idiomatic version:

```ruby
def cost_tokens
  totals = messages.unscope(:order).select(
    "COALESCE(SUM(input_tokens), 0) AS input",
    "COALESCE(SUM(output_tokens), 0) AS output"
  ).take
  { input: totals.input, output: totals.output }
end
```

Or simpler still:

```ruby
def cost_tokens
  {
    input:  messages.sum(:input_tokens),
    output: messages.sum(:output_tokens),
  }
end
```

Two queries instead of one, but `sum` already coalesces nils to 0 in Active Record, and this reads like it does what it says. The performance difference is irrelevant for chat headers (called once per request).

**Specific edit:** consider replacing the `pick + Arel.sql` with two `sum` calls. If you prefer one query, fine — but lose the `Arel.sql` raw strings; they're not needed for `SUM` of plain columns.

### 9. The `tool_calls.replay_payload` migration doesn't carry forward existing data

The migration adds `tool_calls.replay_payload` as nullable jsonb but does not copy existing tool-call metadata into it. That's correct — there is no existing `thought_signature` data to migrate, because the bug is that we never persisted it. New rows get the new column populated; old rows have null. Confirmed fine. No edit; just calling out that this is intentional.

### 10. Style nit: the migration's `up`/`down` is more verbose than `change`

01a used `def change`, 01b uses `def up` / `def down`. The `up` includes data migration code (`Message.where(...).find_each`), which forces non-reversible logic. That's the right reason to drop `change`. But the `down` block tries to reverse the data migration — which means if anyone runs `rails db:rollback` after this ships, it will partially reconstruct the old shape from the new shape. That's almost never useful in practice and creates a maintenance burden if `Message` ever changes.

**Specific edit:** either delete the `down` data restoration entirely (just `remove_column` calls; if you rollback, you accept data loss on these new columns), or make the migration `irreversible` and stop pretending. The current `down` is theater.

```ruby
def down
  raise ActiveRecord::IrreversibleMigration
end
```

Or the schema-only down:

```ruby
def down
  add_column :messages, :thinking_signature, :string
  remove_column :messages, :replay_payload
  remove_column :messages, :cached_tokens
  remove_column :messages, :cache_creation_tokens
  remove_column :messages, :reasoning_skip_reason
  remove_column :tool_calls, :replay_payload
end
```

Either is fine. The current "carefully reverse the data migration" version is over-engineered for the realistic rollback scenario.

### 11. Style: the spec still uses dashes inconsistently

Mixed em-dashes (`—`) and double-dashes in prose. Pick one. Not a code issue, just polish.

---

## Anything 01b broke

Nothing significant. The compression was clean. Two minor regressions:

- **The `private` keyword above class methods (item 5).** Round 1 didn't have this because the helpers lived in a separate class. Round 2 inlined them and accidentally produced ineffective `private` declarations.
- **The `into:` parameter (item 1).** Round 1 had `Message::ProviderPayload.new(rlm)` which was wrong but at least had a clear receiver. Round 2 inlined to `Message.from_provider_response(rlm, into: msg)` which is technically a class method but reads as a service object. Instance method, please.
- **Empty-response fallback location (item 2).** Round 1 had it scattered. My round-1 advice said "put it on Message." Looking at it consolidated, that was wrong — the apology copy belongs in the streaming concern. Reverse my round-1 advice on that single point.

---

## Summary of concrete edits before shipping

1. Rename `Message.from_provider_response(rlm, into:, ...)` → instance method `Message#record_provider_response!(rlm, ...)`. Drop the `into:` parameter.
2. Move `fallback_content_for_empty_response` from `Message` to `StreamsAiResponse` (private method on the concern).
3. Fix the `private` keyword above class methods — convert helpers to instance methods or wrap properly.
4. Simplify `cost_tokens` to two `sum` calls or use `select`/`take`; drop `Arel.sql`.
5. Decide on migration `down`: either delete the data-restoration code or mark `irreversible`.

After those, ship it. The spec's diagnosis, schema, replay rules, token accounting, and test plan are all correct. The remaining issues are surface-level Ruby/Rails style, not architecture.
