# RubyLLM Extended Thinking Support

**Date:** 2026-01-03
**PR:** https://github.com/crmne/ruby_llm/pull/552
**Branch:** `swombat/ruby_llm` main branch (ready to use)

## Summary

RubyLLM now supports Extended Thinking (reasoning) for models that expose their internal reasoning process. This allows applications to access both the model's thinking and final response.

## Quick Start

```ruby
# Enable thinking on a chat
chat = RubyLLM.chat(model: 'claude-opus-4-5-20251101')
  .with_thinking(budget: :medium)

response = chat.ask("What is 15 * 23?")
response.thinking  # => "Let me work through this step by step..."
response.content   # => "345"
```

## Key APIs

### Enabling Thinking

```ruby
chat.with_thinking(budget: :medium)  # :low, :medium, :high, or Integer
chat.thinking_enabled?               # => true/false
```

### Accessing Thinking Content

```ruby
# Non-streaming
response = chat.ask("Question")
response.thinking  # The model's reasoning (String or nil)
response.content   # The final answer

# Streaming
chat.ask("Question") do |chunk|
  chunk.thinking  # Thinking fragment (may be nil for some chunks)
  chunk.content   # Content fragment
end
```

## Supported Models

Models must have the `reasoning` capability:

| Provider | Models |
|----------|--------|
| Anthropic | claude-opus-4-5-*, claude-opus-4-*, claude-sonnet-4-* |
| Gemini | gemini-2.5-*, gemini-3-* |
| OpenAI/Grok | grok-* (via OpenRouter or xAI) |

Check capability: `model.supports?('reasoning')`

## Budget Translation

| Symbol | Anthropic | Gemini 2.5 | Gemini 3 |
|--------|-----------|------------|----------|
| `:low` | 1,024 tokens | 1,024 tokens | "low" |
| `:medium` | 10,000 tokens | 8,192 tokens | "medium" |
| `:high` | 32,000 tokens | 24,576 tokens | "high" |

Integer values are passed directly as token budgets.

## ActiveRecord Integration

### New Migration Columns

If upgrading, add these columns to your messages table:

```ruby
add_column :messages, :thinking, :text
add_column :messages, :thinking_signature, :text
```

New installations include these automatically.

### Usage with Persisted Chats

```ruby
chat_record = Chat.create!
chat_record.with_thinking(budget: :medium)

response = chat_record.ask("Complex question")

# Thinking is automatically persisted
message = chat_record.messages.last
message.thinking  # => "Step by step reasoning..."
```

## Streaming Implementation Pattern

For applications that need to display thinking and content separately:

```ruby
thinking_buffer = ""
content_buffer = ""

chat.ask("Question") do |chunk|
  if chunk.thinking
    thinking_buffer << chunk.thinking
    update_thinking_ui(thinking_buffer)
  end

  if chunk.content
    content_buffer << chunk.content
    update_content_ui(content_buffer)
  end
end

final_response  # Still returns the complete Message object
```

## Error Handling

```ruby
begin
  chat.with_thinking(budget: :medium)
rescue RubyLLM::UnsupportedFeatureError => e
  # Model doesn't support thinking
  puts e.message  # => "Model 'gpt-4o' does not support extended thinking"
end
```

## Migration from Custom Implementations

If your app previously implemented custom thinking handling:

1. **Remove custom thinking extraction** - RubyLLM now handles this
2. **Use `response.thinking`** instead of parsing raw responses
3. **Use `chunk.thinking`** in streaming blocks instead of custom parsing
4. **Add database columns** if persisting with ActiveRecord
5. **Replace custom budget logic** with `with_thinking(budget:)`

## Files Changed in RubyLLM

Key files for reference:

- `lib/ruby_llm/chat.rb` - `with_thinking`, `thinking_enabled?`
- `lib/ruby_llm/message.rb` - `thinking` attribute
- `lib/ruby_llm/stream_accumulator.rb` - Thinking accumulation
- `lib/ruby_llm/providers/*/chat.rb` - Provider-specific implementations
- `lib/ruby_llm/providers/*/streaming.rb` - Streaming thinking extraction
