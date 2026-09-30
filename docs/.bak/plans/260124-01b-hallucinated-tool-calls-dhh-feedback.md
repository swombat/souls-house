# DHH Review: Hallucinated Tool Calls Implementation Plan (Revision B)

**Date:** 2026-01-24
**Reviewing:** 260124-01b-hallucinated-tool-calls.md

## Overall Assessment

This revision shows genuine progress. The spec has dropped the absurd tool inference engine and the escape-aware JSON parser. It now does something defensible: strip garbage JSON, and for one specific tool where the response echoes inputs, opportunistically save the data.

However, I still have concerns. The brace-counting approach will fail on nested JSON with string values containing braces. The `maybe_save_memory` method has knowledge of SaveMemoryTool's response format baked directly into the Message model. And the `find_json_end` method is still a hand-rolled parser, just a simpler one.

This is closer to Rails-worthy, but not there yet.

## Critical Issues

### 1. Brace Counting Will Fail on Real JSON

```ruby
def find_json_end(str)
  depth = 0
  str.each_char.with_index do |char, i|
    depth += 1 if char == "{"
    depth -= 1 if char == "}"
    return i if depth == 0
  end
  nil
end
```

Consider this hallucinated content:

```
{"success": true, "content": "User said {something in braces}"}Hello world
```

The brace counter will find the wrong closing brace. The JSON ends at position 58, but this method will return position 42.

If we are going to parse JSON at all, use `JSON.parse`. If the JSON is malformed, strip it with a simpler heuristic.

### 2. SaveMemoryTool Knowledge Leaks Into Message

```ruby
def maybe_save_memory(json_str)
  return unless agent&.tools&.include?(SaveMemoryTool)

  parsed = JSON.parse(json_str) rescue return
  return unless parsed["memory_type"] && parsed["content"]
  return unless AgentMemory.memory_types.key?(parsed["memory_type"])

  agent.memories.create(...)
end
```

The Message model now knows:
- That SaveMemoryTool exists
- The shape of its response format
- How to create AgentMemory records
- The valid memory types

This is inappropriate coupling. If SaveMemoryTool's response format changes, Message needs to change. That violates encapsulation.

### 3. The Regex Detection is Still Problematic

```ruby
content.strip.match?(/\A\{.+?\}[^}]/m)
```

This requires at least one character after the closing brace that is not a closing brace. What if the hallucinated JSON is followed by a newline? Or what if the entire message is just the JSON with nothing after it? The `[^}]` anchor seems arbitrary.

## Improvements Needed

### Simplify Further: Just Strip

The honest approach is simpler still. We do not know what the model intended. We do not know if the hallucinated memory content is what the user wanted. Strip the JSON, let the user see the real response, and move on.

If users genuinely need the memory saved, they can ask the model to save it again - properly, through the actual tool call flow.

```ruby
# app/models/message.rb

def has_json_prefix?
  return false unless role == "assistant" && content.present?
  content.strip.start_with?("{")
end

def strip_json_prefix!
  return unless has_json_prefix?

  stripped = content.strip
  # Try JSON.parse to find where the object ends
  # If it fails, fall back to regex
  stripped = strip_valid_json(stripped) || strip_by_heuristic(stripped)

  update!(content: stripped) if stripped != content
end

private

def strip_valid_json(text)
  # Attempt to find valid JSON at the start
  (1..text.length).each do |i|
    candidate = text[0...i]
    next unless candidate.end_with?("}")
    begin
      JSON.parse(candidate)
      remainder = text[i..].to_s.strip
      return remainder.empty? ? nil : remainder
    rescue JSON::ParserError
      next
    end
  end
  nil
end

def strip_by_heuristic(text)
  # If JSON.parse cannot find valid JSON, use simple heuristic:
  # Find first "}" followed by non-JSON content
  if (match = text.match(/\}(\s*[A-Za-z])/))
    text[match.begin(1)..].strip
  else
    text # Cannot determine where JSON ends, leave it alone
  end
end
```

This approach:
1. Tries to use `JSON.parse` properly to find JSON boundaries
2. Falls back to a simple heuristic if the JSON is malformed
3. Does not pretend to know what tool was "called"
4. Does not create records based on hallucinated content

### If Memory Saving is Truly Required

If the product requirement genuinely demands saving these hallucinated memories (I remain skeptical), extract it:

```ruby
# app/models/concerns/hallucination_recovery.rb
module HallucinationRecovery
  extend ActiveSupport::Concern

  def recover_hallucinated_content
    return unless has_json_prefix? && agent&.tools&.include?(SaveMemoryTool)

    extracted = extract_json_prefix
    return unless extracted

    SaveMemoryTool.recover_from_hallucination(extracted[:json], agent)
    update!(content: extracted[:remainder])
  end
end

# app/tools/save_memory_tool.rb
def self.recover_from_hallucination(json_string, agent)
  parsed = JSON.parse(json_string) rescue return
  return unless recoverable_response?(parsed)

  agent.memories.create(
    content: parsed["content"],
    memory_type: parsed["memory_type"]
  )
end

def self.recoverable_response?(parsed)
  parsed["memory_type"].in?(AgentMemory.memory_types.keys) &&
    parsed["content"].present?
end
```

This keeps the knowledge of response formats in the tool where it belongs.

## What Works Well

1. **Acknowledged the core insight** - The spec correctly identifies that we cannot reverse-engineer tool inputs from outputs in general
2. **Scoped to one tool** - Not trying to build a generic inference engine anymore
3. **Transaction wrapping** - The `strip_json_prefix!` method properly wraps in a transaction
4. **Simple controller action** - Follows existing patterns, no over-complicated error handling
5. **Reasonable line count** - This is approximately the right size for the feature

## Summary

The revision addresses the major architectural concerns from my previous review. It is no longer building an inference engine. It is no longer writing a bespoke JSON parser with escape handling.

But it still has coupling issues (Message knows about SaveMemoryTool) and the brace-counting parser will fail on real-world JSON with nested braces in strings.

My recommendation: Ship the strip-only version first. Use `JSON.parse` properly to find JSON boundaries. Do not save hallucinated memories - that is building fiction on top of hallucination. If users genuinely need the memory functionality, let them trigger a real tool call.

The spec is close. One more revision focused on proper JSON boundary detection and removing the SaveMemoryTool coupling would make it Rails-worthy.

## Verdict

Not quite there, but salvageable. The direction is correct. Fix the JSON parsing approach and move the tool-specific recovery logic into the tool itself if it is truly needed.
