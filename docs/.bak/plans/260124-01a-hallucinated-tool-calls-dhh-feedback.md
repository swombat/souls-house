# DHH Review: Hallucinated Tool Calls Implementation Plan

**Date:** 2026-01-24
**Reviewing:** 260124-01a-hallucinated-tool-calls.md

## Overall Assessment

This plan is over-engineered. It attempts to reverse-engineer hallucinated tool responses back into tool calls, then execute them - a brittle approach that will break as soon as tool response formats change. The spec confuses what models *output* (a fake response JSON) with what tools *need* (input parameters). We are building archaeology when we should be building demolition.

The actual requirement is simple: strip the garbage JSON from the message content and optionally record that something was stripped. We do not need to execute these "tool calls" - the model already hallucinated the response it wanted. Executing the tool just to get the same response is cargo-cult correctness.

## Critical Issues

### 1. Fundamental Misunderstanding of the Problem

The hallucinated JSON is a *response*, not a *request*. Look at the example:

```json
{success: true, memory_type: "journal", content: "..."}
```

This is what `SaveMemoryTool#execute` *returns*, not what it *receives*. The plan attempts to parse this response and map it back to tool parameters - a fragile inversion that assumes we can divine intent from output.

The model already "decided" what the memory should contain. It is in the JSON. If we want to save it, just save it directly. But even that is questionable - why do we trust hallucinated content more than any other hallucination?

### 2. The Model is Bloating

Adding 150+ lines of JSON parsing, tool inference, and execution logic to `Message` violates the Single Responsibility Principle. The Message model is already 395 lines. This makes it a 550+ line behemoth.

A `Message` should know how to represent a message, not how to parse malformed LLM output and orchestrate tool execution. This is the wrong home for this logic.

### 3. The JSON Parser is a Maintenance Nightmare

```ruby
def extract_json_object(str)
  depth = 0
  in_string = false
  escape_next = false
  # ...50 lines of character-by-character parsing
end
```

We are writing a JSON parser inside a Rails model. This is a red flag. If the standard library cannot parse it, we should not be writing bespoke character-level parsers. Either the JSON is valid (use `JSON.parse`) or it is malformed garbage we should strip with a regex.

The "handle unquoted keys" hack (`json_str.gsub(/(\w+):/, '"\1":')`) is particularly fragile - it will mangle any JSON containing URLs or text with colons.

### 4. Tool Inference is Guesswork

```ruby
def infer_tool_name(parsed_json)
  if parsed_json.key?("memory_type") && parsed_json.key?("content")
    "SaveMemoryTool"
  elsif parsed_json.key?("type") && parsed_json["type"].to_s.start_with?("board")
    "WhiteboardTool"
  # ...
end
```

We are matching response shapes to tool names. This breaks whenever:
- A tool adds or removes a response field
- Two tools have similar response shapes
- A new tool is added (requires updating this switch statement)

This is the antithesis of DRY - every tool change requires remembering to update this mapping.

### 5. The Controller Error Handling is Too Verbose

```ruby
respond_to do |format|
  format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "No hallucinated tool calls detected" }
  format.json { render json: { error: "No hallucinated tool calls detected" }, status: :unprocessable_entity }
end
```

This pattern repeats three times. Compare to the existing `retry` action which is 8 lines total.

## Improvements Needed

### Simplify the Requirement

The actual need is:
1. Detect messages with JSON-prefixed garbage
2. Let the user strip it
3. Record that we stripped something (for debugging)

That is it. No tool execution. No response parsing. No inference engines.

### Proposed Simple Implementation

**Message model additions (~15 lines):**

```ruby
# app/models/message.rb

def has_json_prefix?
  return false unless role == "assistant" && content.present?
  content.strip.match?(/\A\{.+\}[^}]/m)
end

def strip_json_prefix!
  return unless has_json_prefix?

  # Find where the real content starts (after all JSON blocks)
  remaining = content.strip
  while remaining.start_with?("{") && (close = remaining.index(/\}[^}]/))
    remaining = remaining[(close + 1)..].strip
  end

  update!(content: remaining)
end

def fixable
  has_json_prefix? && agent.present?
end
```

**Controller action (~10 lines):**

```ruby
def strip_json_prefix
  @message = Message.find(params[:id])
  authorize_message_chat!

  @message.strip_json_prefix!
  redirect_to account_chat_path(@chat.account, @chat)
end
```

This is 25 lines instead of 250. It does what is needed. It does not pretend to execute hallucinated tool calls.

### If Tool Execution is Truly Required

If the product requirement genuinely demands executing these "tools", extract the logic:

```ruby
# app/services/hallucination_fixer.rb - but honestly, just put it in a concern

module HallucinationFixer
  def fix_hallucinated_tool_calls!
    # All the complex logic lives here, not in Message
  end
end
```

But I question whether this is truly required. The model hallucinated a response. The "tool call" never happened. Executing it now does not make the history accurate - it makes it fiction pretending to be fact.

### Frontend is Fine

The button approach is reasonable. Use `router.reload()` after the action completes. Do not over-engineer the fetch handling.

## What Works Well

1. **Detection approach is sound** - Looking for JSON-prefixed content is the right heuristic
2. **Route placement is correct** - Member action on messages resource
3. **Authorization pattern follows existing code** - Matches `set_message` in existing controller
4. **Button visibility logic is correct** - `fixable` attribute on JSON output

## Refactored Approach

Strip this plan down to:

1. Add `has_json_prefix?` detection (5 lines)
2. Add `strip_json_prefix!` method (10 lines)
3. Add `fixable` JSON attribute (1 line)
4. Add controller action (10 lines)
5. Add route (1 line)
6. Add frontend button (15 lines)
7. Add tests (20 lines)

Total: ~60 lines of new code instead of ~300.

If after shipping this minimal version, users genuinely need the tool calls to be "executed", revisit then with real usage data. Do not build speculation.

## Summary

The plan commits the cardinal sin of over-engineering: solving problems we do not have. The JSON parsing is fragile, the tool inference is a maintenance burden, and the model is gaining responsibilities it should not own.

Ship the simple version. Strip the JSON. Move on. The models will eventually stop hallucinating, or we will switch models, or we will find the simple fix is good enough. Do not build a Rube Goldberg machine to clean up after misbehaving LLMs.

This plan, as written, is not Rails-worthy. The refactored approach would be.
