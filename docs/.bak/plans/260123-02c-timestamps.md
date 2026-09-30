# Conversation Timestamps - Final Implementation Specification

**Plan ID:** 260123-02c
**Created:** 2026-01-23
**Updated:** 2026-01-24
**Status:** IN PROGRESS
**Revision:** Fourth iteration (adding per-message timestamps)

---

## Executive Summary

Add time awareness to agent conversations by:
1. Injecting the current time into the system prompt
2. Prepending timestamps to every message in the context

This gives agents both "what time is it now" and "when was each message sent"--necessary for meaningful time-based reasoning.

---

## Implementation

### Step 1: Add User Timezone Helpers

- [x] Add memoized timezone lookup to Chat model

```ruby
# app/models/chat.rb
# Add to private section, after participant_description method

def user_timezone
  @user_timezone ||= ActiveSupport::TimeZone[recent_user_timezone || "UTC"]
end

def recent_user_timezone
  messages.joins(user: :profile)
          .where.not(user_id: nil)
          .order(created_at: :desc)
          .limit(1)
          .pick("profiles.timezone")
end
```

### Step 2: Update System Prompt

- [x] Add current time line to `system_message_for`

Add this line before "You are participating in a group conversation." (around line 473):

```ruby
parts << "Current time: #{Time.current.in_time_zone(user_timezone).strftime('%Y-%m-%d %H:%M %Z')}"
```

### Step 3: Update Message Context Methods

- [x] Pass timezone to `format_message_for_context`

```ruby
def messages_context_for(agent, thinking_enabled: false)
  tz = user_timezone
  messages.includes(:user, :agent).order(:created_at)
    .reject { |msg| msg.content.blank? }
    .map { |msg| format_message_for_context(msg, agent, tz, thinking_enabled: thinking_enabled) }
end
```

- [x] Prepend timestamps in `format_message_for_context`

```ruby
def format_message_for_context(message, current_agent, timezone, thinking_enabled: false)
  timestamp = message.created_at.in_time_zone(timezone).strftime("[%Y-%m-%d %H:%M]")

  text_content = if message.agent_id == current_agent.id
    "#{timestamp} #{message.content}"
  elsif message.agent_id.present?
    "#{timestamp} [#{message.agent.name}]: #{message.content}"
  else
    name = message.user&.full_name.presence || message.user&.email_address&.split("@")&.first || "User"
    "#{timestamp} [#{name}]: #{message.content}"
  end

  role = message.agent_id == current_agent.id ? "assistant" : "user"

  file_paths = message.file_paths_for_llm
  content = if file_paths.present?
    RubyLLM::Content.new(text_content, file_paths)
  else
    text_content
  end

  result = { role: role, content: content }

  if thinking_enabled && role == "assistant" && message.thinking.present?
    result[:thinking] = message.thinking
  end

  result
end
```

---

## Testing Strategy

- [x] Add tests for the new functionality

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

    assert_equal "America/New_York", @chat.send(:user_timezone).name
  end

  test "user_timezone falls back to UTC when no timezone set" do
    user = users(:one)
    user.profile.update!(timezone: nil)
    @chat.messages.create!(role: "user", content: "Hello", user: user)

    assert_equal "UTC", @chat.send(:user_timezone).name
  end

  test "user_timezone falls back to UTC when no human messages" do
    assert_equal "UTC", @chat.send(:user_timezone).name
  end

  test "system_message_for includes current time" do
    system_msg = @chat.system_message_for(@agent)
    assert_match(/Current time: \d{4}-\d{2}-\d{2} \d{2}:\d{2} \w+/, system_msg[:content])
  end

  test "format_message_for_context prepends timestamp to user messages" do
    user = users(:one)
    message = @chat.messages.create!(role: "user", content: "Hello world", user: user)
    tz = ActiveSupport::TimeZone["UTC"]

    formatted = @chat.send(:format_message_for_context, message, @agent, tz)

    assert_match(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\] \[.+\]: Hello world/, formatted[:content])
  end

  test "format_message_for_context prepends timestamp to agent messages" do
    message = @chat.messages.create!(role: "assistant", content: "Hi there", agent: @agent)
    tz = ActiveSupport::TimeZone["UTC"]

    formatted = @chat.send(:format_message_for_context, message, @agent, tz)

    assert_match(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\] Hi there/, formatted[:content])
  end

  test "messages_context_for includes timestamps on all messages" do
    user = users(:one)
    @chat.messages.create!(role: "user", content: "Question", user: user)
    @chat.messages.create!(role: "assistant", content: "Answer", agent: @agent)

    context = @chat.messages_context_for(@agent)

    context.each do |msg|
      assert_match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}\]/, msg[:content].to_s)
    end
  end
end
```

---

## File Changes Summary

| File | Changes |
|------|---------|
| `app/models/chat.rb` | Add 2 methods (~10 lines), modify 2 methods |
| `test/models/chat_timestamp_test.rb` | New file (~50 lines) |

**Total: ~60 lines including tests**

---

## Implementation Checklist

- [x] Add `recent_user_timezone` private method to Chat
- [x] Add `user_timezone` private method to Chat (memoized)
- [x] Add current time line to `system_message_for`
- [x] Update `messages_context_for` to pass timezone
- [x] Update `format_message_for_context` to accept timezone and prepend timestamps
- [x] Create `test/models/chat_timestamp_test.rb` with 7 tests
- [ ] Run `rails test test/models/chat_timestamp_test.rb`
- [ ] Manual testing: verify agents can reason about message timing

---

## What This Does NOT Include

Per DHH's feedback, the following remain intentionally omitted:

1. **Gap detection** - Unnecessary complexity; agents can subtract
2. **Multiple timestamp formats** - One format only: `[YYYY-MM-DD HH:MM]`
3. **Same-minute suppression** - Premature optimization
4. **Conditional timestamp display** - Every message gets a timestamp, no exceptions

---

*This specification is ready for implementation.*
