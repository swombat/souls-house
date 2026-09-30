# RubyLLM Extended Thinking Support

## Overview

This document outlines the changes required in RubyLLM to properly support extended thinking/reasoning features across multiple AI providers. Currently, RubyLLM (v1.9.1) does not expose thinking content in streaming responses or handle thinking blocks in conversation history.

## Problem Statement

When using Anthropic's extended thinking feature via RubyLLM:

1. **Thinking content is not captured during streaming** - The `build_chunk` method in `providers/anthropic/streaming.rb` only extracts `data.dig('delta', 'text')`, ignoring `thinking_delta` events.

2. **Thinking blocks are lost in response parsing** - The `extract_text_content` method in `providers/anthropic/chat.rb` only extracts blocks where `type == 'text'`, discarding thinking blocks.

3. **Conversation history breaks with thinking enabled** - When thinking is enabled, Anthropic requires previous assistant messages to include their thinking blocks. Since we don't store/replay thinking content, multi-turn conversations fail with:
   ```
   messages.3.content.0.type: Expected `thinking` or `redacted_thinking`, but found `text`.
   When `thinking` is enabled, a final `assistant` message must start with a thinking block.
   ```

4. **No unified API for thinking across providers** - Each provider has different thinking implementations, but RubyLLM doesn't abstract this.

## Provider-Specific Thinking Implementations

### Anthropic Claude

**Request Format:**
```ruby
{
  thinking: { type: "enabled", budget_tokens: 10000 },
  max_tokens: 18000  # Must be > budget_tokens
}
```

**Streaming Events:**
- `content_block_delta` with `delta.type = 'text_delta'` for regular text
- `content_block_delta` with `delta.type = 'thinking_delta'` for thinking content

**Response Content Blocks:**
```json
{
  "content": [
    { "type": "thinking", "thinking": "..." },
    { "type": "text", "text": "..." }
  ]
}
```

**Conversation History Requirement:**
When thinking is enabled, assistant messages in history must include thinking blocks (or `redacted_thinking` placeholders).

### Google Gemini

**Request Format (Gemini 3):**
```python
thinking_config=ThinkingConfig(
    include_thoughts=True,
    thinking_level="low"  # or "high"
)
```

**Request Format (Gemini 2.5):**
```python
thinking_config=ThinkingConfig(
    thinking_budget=8192  # tokens
)
```

**Response Format:**
- Parts have a `thought` boolean flag
- Access via `response.candidates[0].content.parts`
- Iterate parts, check `part.thought` to identify thought summaries

**Thought Signatures:**
- Returned as encrypted representations for multi-turn continuity
- Must be passed back unchanged in subsequent turns
- Required for function calling with Gemini 3 models

### OpenAI o1/o3 Series

**Request Format:**
```json
{
  "reasoning": { "effort": "medium" },
  "max_completion_tokens": 10000
}
```
Note: Uses `max_completion_tokens` instead of `max_tokens`.

**Important Limitation:**
Reasoning tokens are NOT exposed via the API. They are billed as output tokens but the actual reasoning content is hidden. The API returns only the final answer.

### xAI Grok

**Request Format:**
```json
{
  "reasoning_effort": "high",
  "reasoning": { "enabled": true }
}
```

**Response Format:**
- Reasoning available via `reasoning_content` or `encrypted_content` field
- Can be enabled/disabled per request

## Proposed RubyLLM Changes

### 1. Add `thinking` Attribute to Message Class

**File:** `lib/ruby_llm/message.rb`

```ruby
class Message
  attr_reader :role, :model_id, :tool_calls, :tool_call_id, :input_tokens, :output_tokens,
              :cached_tokens, :cache_creation_tokens, :raw, :thinking

  def initialize(options = {})
    # ... existing code ...
    @thinking = options[:thinking]
  end

  def to_h
    {
      # ... existing fields ...
      thinking: thinking
    }.compact
  end
end
```

### 2. Parse Thinking in Anthropic Streaming

**File:** `lib/ruby_llm/providers/anthropic/streaming.rb`

```ruby
def build_chunk(data)
  Chunk.new(
    role: :assistant,
    model_id: extract_model_id(data),
    content: extract_content_delta(data),
    thinking: extract_thinking_delta(data),
    # ... other fields ...
  )
end

def extract_content_delta(data)
  return data.dig('delta', 'text') if data.dig('delta', 'type') == 'text_delta'
  nil
end

def extract_thinking_delta(data)
  return data.dig('delta', 'thinking') if data.dig('delta', 'type') == 'thinking_delta'
  nil
end
```

### 3. Parse Thinking in Anthropic Response

**File:** `lib/ruby_llm/providers/anthropic/chat.rb`

```ruby
def parse_completion_response(response)
  data = response.body
  content_blocks = data['content'] || []

  text_content = extract_text_content(content_blocks)
  thinking_content = extract_thinking_content(content_blocks)
  tool_use_blocks = Tools.find_tool_uses(content_blocks)

  build_message(data, text_content, thinking_content, tool_use_blocks, response)
end

def extract_thinking_content(blocks)
  thinking_blocks = blocks.select { |c| c['type'] == 'thinking' }
  thinking_blocks.map { |c| c['thinking'] }.join
end

def build_message(data, content, thinking, tool_use_blocks, response)
  Message.new(
    # ... existing fields ...
    thinking: thinking.presence
  )
end
```

### 4. Include Thinking in Message Formatting

**File:** `lib/ruby_llm/providers/anthropic/chat.rb`

When formatting assistant messages for the API, include thinking blocks:

```ruby
def format_basic_message(msg)
  content_blocks = []

  # Include thinking block if present (or redacted_thinking placeholder)
  if msg.thinking.present?
    content_blocks << { type: 'thinking', thinking: msg.thinking }
  elsif msg.role == :assistant && thinking_enabled?
    # Placeholder for redacted thinking when original thinking is unavailable
    content_blocks << { type: 'redacted_thinking', data: '' }
  end

  # Add text content
  content_blocks.concat(Media.format_content(msg.content))

  {
    role: convert_role(msg.role),
    content: content_blocks
  }
end
```

### 5. Add Gemini Thinking Support

**File:** `lib/ruby_llm/providers/gemini/streaming.rb`

Parse thought parts in streaming:

```ruby
def build_chunk(data)
  parts = data.dig('candidates', 0, 'content', 'parts') || []

  text_parts = parts.reject { |p| p['thought'] }.map { |p| p['text'] }.join
  thought_parts = parts.select { |p| p['thought'] }.map { |p| p['text'] }.join

  Chunk.new(
    content: text_parts.presence,
    thinking: thought_parts.presence,
    # ... other fields ...
  )
end
```

**File:** `lib/ruby_llm/providers/gemini/chat.rb`

Handle thought signatures for multi-turn conversations.

### 6. Add xAI Grok Reasoning Support

**File:** `lib/ruby_llm/providers/openai/streaming.rb` (xAI uses OpenAI-compatible API)

```ruby
def build_chunk(data)
  Chunk.new(
    content: data.dig('choices', 0, 'delta', 'content'),
    thinking: data.dig('choices', 0, 'delta', 'reasoning_content'),
    # ... other fields ...
  )
end
```

### 7. Add Thinking Configuration Helpers

**File:** `lib/ruby_llm/chat.rb` (or new file `lib/ruby_llm/thinking.rb`)

```ruby
module RubyLLM
  class Chat
    def with_thinking(budget: 10000, effort: nil)
      case detect_provider
      when :anthropic
        with_params(
          thinking: { type: "enabled", budget_tokens: budget },
          max_tokens: budget + 8000
        )
      when :gemini
        with_params(
          thinking_config: { include_thoughts: true, thinking_budget: budget }
        )
      when :openai
        with_params(
          reasoning: { effort: effort || "medium" },
          max_completion_tokens: budget
        )
      when :xai
        with_params(
          reasoning: { enabled: true },
          reasoning_effort: effort || "high"
        )
      end
    end
  end
end
```

## Testing Requirements

Each provider should have tests for:

1. **Streaming with thinking** - Verify `chunk.thinking` is populated
2. **Non-streaming with thinking** - Verify `message.thinking` is populated
3. **Multi-turn conversations** - Verify thinking blocks are included in conversation history
4. **Thinking disabled** - Verify no regression when thinking is not enabled
5. **Provider-specific edge cases** - e.g., Gemini thought signatures, OpenAI hidden reasoning

## Migration Notes

- The `thinking` attribute should be optional and default to `nil`
- Existing code that doesn't use thinking should continue to work unchanged
- The `with_thinking` helper should be additive, not breaking existing `with_params` usage

## References

- [Anthropic Extended Thinking](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking)
- [Google Gemini Thinking](https://ai.google.dev/gemini-api/docs/thinking)
- [OpenAI Reasoning Models](https://platform.openai.com/docs/guides/reasoning)
- [xAI Grok Reasoning](https://docs.x.ai/docs/guides/reasoning)
- [OpenRouter Reasoning Tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)

## Priority

The most critical change is Anthropic support, as it's the only provider where:
1. Thinking content IS exposed via the API
2. Thinking blocks ARE required in conversation history

Gemini support is second priority due to thought signatures.

OpenAI o-series reasoning is lower priority since reasoning tokens aren't exposed.

xAI Grok support depends on whether `reasoning_content` is reliably returned.
