# Conversation Timestamps - Implementation Specification

**Plan ID:** 260123-02a
**Created:** 2026-01-23
**Status:** Ready for Implementation
**Revision:** First iteration

## Executive Summary

Add time awareness to agent conversations by embedding timestamps in message context and current time in system prompts. The implementation uses a smart compression strategy: full timestamps after significant gaps, compact timestamps for recent messages, and relative gap indicators for large time jumps. This provides AI agents with temporal context while minimizing token overhead.

## Architecture Overview

### Core Design Principles

1. **Token Efficiency**: Use progressive timestamp detail - only include full timestamps when temporal context is ambiguous
2. **AI Intelligibility**: Format timestamps in ISO-like format that LLMs parse well, not human-friendly formats
3. **Non-Intrusive**: Timestamps prefix message content, maintaining clean conversation flow
4. **Timezone Aware**: Use the most recent human participant's timezone for all time formatting

### Timestamp Strategy

| Scenario | Format | Example | Tokens |
|----------|--------|---------|--------|
| System prompt (current time) | Full ISO + timezone name | `Current time: 2026-01-23T14:32:00 (Europe/London)` | ~15 |
| First message / after >24h gap | Full date + time | `[2026-01-23 14:32]` | ~8 |
| After 1-24h gap | Time with gap indicator | `[14:32, 3h later]` | ~6 |
| Within 1h of previous | Time only | `[14:32]` | ~3 |
| Same minute | No timestamp | (none) | 0 |

### Token Impact Estimate

For a typical 20-message conversation:
- System prompt addition: ~15 tokens
- Full timestamps (2-3 per conversation): ~24 tokens
- Compact timestamps (15-17 messages): ~60 tokens
- **Total overhead: ~100 tokens** (roughly 0.1% of a typical context window)

## Implementation Steps

### Step 1: Add Time Context Helper Methods to Chat

- [ ] Add methods for determining user timezone and formatting timestamps

```ruby
# app/models/chat.rb
# Add after the participant_description method (around line 527)

def user_timezone
  # Get timezone from most recent human participant, fallback to UTC
  recent_user = messages.unscope(:order)
                        .where.not(user_id: nil)
                        .order(created_at: :desc)
                        .first&.user

  timezone_name = recent_user&.timezone.presence || "UTC"
  ActiveSupport::TimeZone[timezone_name] || ActiveSupport::TimeZone["UTC"]
end

def current_time_context
  tz = user_timezone
  now = Time.current.in_time_zone(tz)
  "Current time: #{now.strftime('%Y-%m-%dT%H:%M:%S')} (#{tz.name})"
end
```

### Step 2: Add Timestamp Formatting Methods

- [ ] Implement smart timestamp formatting logic

```ruby
# app/models/chat.rb
# Add after current_time_context method

def format_timestamp_for_message(message, previous_message)
  tz = user_timezone
  time = message.created_at.in_time_zone(tz)

  return nil if previous_message && same_minute?(message, previous_message)

  gap = previous_message ? (message.created_at - previous_message.created_at) : nil

  if gap.nil? || gap > 24.hours
    # First message or large gap: full date + time
    "[#{time.strftime('%Y-%m-%d %H:%M')}]"
  elsif gap > 1.hour
    # Moderate gap: time with gap indicator
    hours = (gap / 1.hour).round
    "[#{time.strftime('%H:%M')}, #{hours}h later]"
  else
    # Recent: time only
    "[#{time.strftime('%H:%M')}]"
  end
end

private

def same_minute?(msg1, msg2)
  msg1.created_at.to_i / 60 == msg2.created_at.to_i / 60
end
```

### Step 3: Update System Prompt to Include Current Time

- [ ] Modify `system_message_for` to include time context

```ruby
# app/models/chat.rb
# Update system_message_for method (lines 451-479)

def system_message_for(agent)
  parts = []

  parts << (agent.system_prompt.presence || "You are #{agent.name}.")

  if (memory_context = agent.memory_context)
    parts << memory_context
  end

  if (whiteboard_index = whiteboard_index_context)
    parts << whiteboard_index
  end

  if (topic = conversation_topic_context)
    parts << topic
  end

  if (active_board = active_whiteboard_context)
    parts << active_board
  end

  if Rails.env.development?
    parts << "**DEVELOPMENT TESTING MODE**: You are currently being tested on a development server using a production database backup. Any memories or changes you make will NOT be saved to the production server. This is a safe testing environment."
  end

  # Add current time context
  parts << current_time_context

  parts << "You are participating in a group conversation."
  parts << "Other participants: #{participant_description(agent)}."

  { role: "system", content: parts.join("\n\n") }
end
```

### Step 4: Update Message Context Formatting

- [ ] Modify `messages_context_for` and `format_message_for_context` to include timestamps

```ruby
# app/models/chat.rb
# Update messages_context_for method (lines 511-514)

def messages_context_for(agent, thinking_enabled: false)
  ordered_messages = messages.includes(:user, :agent).order(:created_at)
    .reject { |msg| msg.content.blank? }

  previous_message = nil
  ordered_messages.map do |msg|
    formatted = format_message_for_context(msg, agent,
                                           thinking_enabled: thinking_enabled,
                                           previous_message: previous_message)
    previous_message = msg
    formatted
  end
end
```

- [ ] Update `format_message_for_context` to prepend timestamps

```ruby
# app/models/chat.rb
# Update format_message_for_context method (lines 529-560)

def format_message_for_context(message, current_agent, thinking_enabled: false, previous_message: nil)
  timestamp = format_timestamp_for_message(message, previous_message)

  text_content = if message.agent_id == current_agent.id
    message.content
  elsif message.agent_id.present?
    "[#{message.agent.name}]: #{message.content}"
  else
    name = message.user&.full_name.presence || message.user&.email_address&.split("@")&.first || "User"
    "[#{name}]: #{message.content}"
  end

  # Prepend timestamp if present
  text_content = "#{timestamp} #{text_content}" if timestamp

  role = message.agent_id == current_agent.id ? "assistant" : "user"

  # Include file attachments if present using RubyLLM::Content
  file_paths = message.file_paths_for_llm
  content = if file_paths.present?
    RubyLLM::Content.new(text_content, file_paths)
  else
    text_content
  end

  result = { role: role, content: content }

  # Include thinking for assistant messages when thinking mode is enabled.
  # Only include if both thinking content AND signature are present (Anthropic
  # requires valid cryptographic signatures on thinking blocks).
  if role == "assistant" && thinking_enabled && message.thinking.present?
    result[:thinking] = message.thinking
    result[:thinking_signature] = message.thinking_signature if message.thinking_signature.present?
  end

  result
end
```

### Step 5: Handle Edge Cases

- [ ] Ensure timezone fallback works when no users have participated yet

The `user_timezone` method already handles this by falling back to UTC when:
- No human messages exist in the conversation
- The user has no timezone set in their profile

No additional code needed - the fallback chain is: `recent_user.timezone -> "UTC" -> ActiveSupport::TimeZone["UTC"]`

## Testing Strategy

### Unit Tests

- [ ] Add tests for timestamp formatting logic

```ruby
# test/models/chat_timestamp_test.rb
require "test_helper"

class ChatTimestampTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
    @agent = agents(:one)
  end

  test "user_timezone returns user's timezone when set" do
    user = users(:one)
    user.profile.update!(timezone: "America/New_York")
    @chat.messages.create!(role: "user", content: "Hello", user: user)

    assert_equal "America/New_York", @chat.user_timezone.name
  end

  test "user_timezone falls back to UTC when no timezone set" do
    user = users(:one)
    user.profile.update!(timezone: nil)
    @chat.messages.create!(role: "user", content: "Hello", user: user)

    assert_equal "UTC", @chat.user_timezone.name
  end

  test "user_timezone falls back to UTC when no human messages" do
    assert_equal "UTC", @chat.user_timezone.name
  end

  test "current_time_context includes timezone name" do
    context = @chat.current_time_context
    assert_match(/Current time: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, context)
    assert_match(/\(UTC\)/, context)
  end

  test "format_timestamp_for_message returns nil for same minute" do
    msg1 = @chat.messages.create!(role: "user", content: "First", user: users(:one))
    msg2 = @chat.messages.create!(role: "assistant", content: "Second", agent: @agent)

    # Force same minute
    msg2.update_column(:created_at, msg1.created_at + 30.seconds)

    assert_nil @chat.send(:format_timestamp_for_message, msg2, msg1)
  end

  test "format_timestamp_for_message returns time only for messages within 1 hour" do
    msg1 = @chat.messages.create!(role: "user", content: "First", user: users(:one))
    msg2 = @chat.messages.create!(role: "assistant", content: "Second", agent: @agent)

    msg2.update_column(:created_at, msg1.created_at + 30.minutes)

    timestamp = @chat.send(:format_timestamp_for_message, msg2, msg1)
    assert_match(/^\[\d{2}:\d{2}\]$/, timestamp)
  end

  test "format_timestamp_for_message includes gap indicator for 1-24 hour gaps" do
    msg1 = @chat.messages.create!(role: "user", content: "First", user: users(:one))
    msg2 = @chat.messages.create!(role: "assistant", content: "Second", agent: @agent)

    msg2.update_column(:created_at, msg1.created_at + 3.hours)

    timestamp = @chat.send(:format_timestamp_for_message, msg2, msg1)
    assert_match(/^\[\d{2}:\d{2}, 3h later\]$/, timestamp)
  end

  test "format_timestamp_for_message includes full date for gaps over 24 hours" do
    msg1 = @chat.messages.create!(role: "user", content: "First", user: users(:one))
    msg2 = @chat.messages.create!(role: "assistant", content: "Second", agent: @agent)

    msg2.update_column(:created_at, msg1.created_at + 2.days)

    timestamp = @chat.send(:format_timestamp_for_message, msg2, msg1)
    assert_match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]$/, timestamp)
  end

  test "format_timestamp_for_message includes full date for first message" do
    msg = @chat.messages.create!(role: "user", content: "First", user: users(:one))

    timestamp = @chat.send(:format_timestamp_for_message, msg, nil)
    assert_match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]$/, timestamp)
  end

  test "system_message_for includes current time context" do
    system_msg = @chat.system_message_for(@agent)
    assert_match(/Current time:/, system_msg[:content])
  end

  test "messages_context_for includes timestamps in message content" do
    user = users(:one)
    @chat.messages.create!(role: "user", content: "Hello", user: user)
    @chat.messages.create!(role: "assistant", content: "Hi there", agent: @agent)

    context = @chat.send(:messages_context_for, @agent)

    # First message should have timestamp
    assert_match(/^\[.+\]/, context.first[:content].to_s)
  end
end
```

### Integration Test

- [ ] Test full context building with timestamps

```ruby
# test/models/chat_context_integration_test.rb
require "test_helper"

class ChatContextIntegrationTest < ActiveSupport::TestCase
  test "build_context_for_agent includes time information" do
    chat = chats(:one)
    agent = agents(:one)
    user = users(:one)

    # Set user timezone
    user.profile.update!(timezone: "Europe/London")

    # Create conversation with time gaps
    msg1 = chat.messages.create!(role: "user", content: "Morning message", user: user)
    msg1.update_column(:created_at, 3.hours.ago)

    msg2 = chat.messages.create!(role: "assistant", content: "Morning response", agent: agent)
    msg2.update_column(:created_at, 3.hours.ago + 1.minute)

    msg3 = chat.messages.create!(role: "user", content: "Afternoon message", user: user)
    # Current time - should show gap indicator

    context = chat.build_context_for_agent(agent)

    # System message should include current time with London timezone
    assert_match(/Current time:.+Europe\/London/, context.first[:content])

    # Messages should have appropriate timestamps
    user_messages = context.select { |m| m[:role] == "user" }
    assert user_messages.any? { |m| m[:content].to_s.include?("h later") }
  end
end
```

## Edge Cases Handled

| Case | Behavior |
|------|----------|
| No user timezone set | Falls back to UTC |
| No human messages yet | Uses UTC |
| Invalid timezone string | Falls back to UTC via `ActiveSupport::TimeZone[]` returning nil |
| Messages in same minute | No timestamp shown (avoids clutter) |
| Very long conversation | Token overhead scales linearly but remains minimal |
| Daylight saving transitions | Handled by ActiveSupport::TimeZone |

## File Changes Summary

| File | Changes |
|------|---------|
| `app/models/chat.rb` | Add 4 methods (~40 lines), modify 2 methods (~20 lines changed) |

**Total: ~60 lines of code**

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| ISO-like format over human-friendly | LLMs parse `2026-01-23` better than "January 23rd" |
| Relative gap indicators | Provides context without repeating full dates |
| Timezone in system prompt only | Avoids redundant timezone info in every message |
| Most recent user's timezone | Ensures current user's local time is used |
| Same-minute suppression | Rapid exchanges don't need repeated timestamps |
| No database changes | Timestamps already exist on messages via `created_at` |

## Rails Philosophy Alignment

- **No new models or migrations**: Uses existing `created_at` timestamps
- **Fat model**: All logic lives in Chat model where it belongs
- **Convention over configuration**: Uses Rails' built-in timezone handling
- **DRY**: Single `user_timezone` method used throughout
- **No abstractions**: Direct, readable code without service objects

## Implementation Checklist

- [ ] Add `user_timezone` method to Chat
- [ ] Add `current_time_context` method to Chat
- [ ] Add `format_timestamp_for_message` method to Chat
- [ ] Add `same_minute?` private helper to Chat
- [ ] Update `system_message_for` to include time context
- [ ] Update `messages_context_for` to track previous message
- [ ] Update `format_message_for_context` to prepend timestamps
- [ ] Write unit tests for timestamp formatting
- [ ] Write integration test for full context building
- [ ] Manual testing with various timezone settings
