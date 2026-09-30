# Conversation Timestamps - Implementation Specification

**Plan ID:** 260123-02b
**Created:** 2026-01-23
**Status:** Ready for Implementation
**Revision:** Second iteration (applying DHH feedback)

## Executive Summary

Add time awareness to agent conversations with the simplest possible implementation: inject the current time into the system prompt. This solves the core requirement--agents knowing "what time is it now"--in approximately 15 lines of code.

If message timestamps prove necessary after shipping, they can be added later with a uniform format.

## Design Philosophy

The previous iteration committed the cardinal sin of solving problems that do not yet exist. DHH's critique was clear: four timestamp formats, gap detection, and compression strategies are over-engineering.

This revision asks: what is the smallest change that delivers value?

**Answer**: One line in the system prompt.

## Implementation

### Step 1: Add User Timezone Helper (Memoized)

- [ ] Add memoized timezone lookup to Chat model

```ruby
# app/models/chat.rb
# Add to private section, after participant_description method (around line 527)

def user_timezone
  @user_timezone ||= begin
    user_id = messages.where.not(user_id: nil)
                      .order(created_at: :desc)
                      .limit(1)
                      .pick(:user_id)
    user = User.find_by(id: user_id) if user_id
    ActiveSupport::TimeZone[user&.timezone.presence || "UTC"]
  end
end
```

This method:
- Fires one query, memoized for the request lifecycle
- Falls back to UTC cleanly
- Uses `pick` for efficiency (no model instantiation for the first query)

### Step 2: Update System Prompt

- [ ] Add current time to system_message_for

```ruby
# app/models/chat.rb
# Update system_message_for method (lines 451-479)
# Add this line before the "You are participating in a group conversation." line:

parts << "Current time: #{Time.current.in_time_zone(user_timezone).strftime('%Y-%m-%d %H:%M %Z')}"
```

The full method becomes:

```ruby
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

  parts << "Current time: #{Time.current.in_time_zone(user_timezone).strftime('%Y-%m-%d %H:%M %Z')}"

  parts << "You are participating in a group conversation."
  parts << "Other participants: #{participant_description(agent)}."

  { role: "system", content: parts.join("\n\n") }
end
```

That is the entire implementation.

## Testing Strategy

- [ ] Add minimal tests for the new functionality

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
end
```

## File Changes Summary

| File | Changes |
|------|---------|
| `app/models/chat.rb` | Add 1 method (~8 lines), modify 1 method (+1 line) |
| `test/models/chat_timestamp_test.rb` | New file (~30 lines) |

**Total: ~40 lines including tests**

## What This Does NOT Include

Per DHH's feedback, the following are intentionally omitted:

1. **Message timestamps** - The AI can reason about time from the current time. If messages need timestamps, we can add them later.
2. **Gap detection** - Unnecessary complexity. AIs can subtract.
3. **Multiple timestamp formats** - If we add message timestamps, there will be ONE format.
4. **Same-minute suppression** - Premature optimization.
5. **Token budget analysis** - One timestamp in the system prompt is ~10 tokens. Not worth analyzing.

## Future Enhancement (If Needed)

If users report that agents are confused about message timing, add uniform timestamps:

```ruby
def messages_context_for(agent, thinking_enabled: false)
  tz = user_timezone
  messages.includes(:user, :agent).order(:created_at)
    .reject { |msg| msg.content.blank? }
    .map { |msg| format_message_for_context(msg, agent, tz, thinking_enabled: thinking_enabled) }
end

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

  # ... rest unchanged ...
end
```

But do not build this until it is needed.

## Implementation Checklist

- [ ] Add `user_timezone` private method to Chat (memoized)
- [ ] Add current time line to `system_message_for`
- [ ] Write tests for timezone lookup and system message
- [ ] Manual testing with various timezone settings

## Rails Philosophy Alignment

- **No new models or migrations**: Uses existing data
- **Minimal code**: ~10 lines of production code
- **Ship and iterate**: Solve the stated problem, add complexity only when proven necessary
- **The simplest thing that could possibly work**: Current time in system prompt
