# Fix Ask All Agents Tool Call Loop

**Plan ID:** 251227-01
**Status:** Complete
**Created:** 2025-12-27

## Problem

When a user clicks "Ask All", if the first agent makes a tool call (e.g., web fetch), the job completes after that tool call and does not:
1. Continue the conversation loop until that agent posts a final text response
2. Move on to the next agent

## Root Cause Analysis

The issue is in how `ManualAgentResponseJob` and `AllAgentsResponseJob` use RubyLLM.

**Current incorrect approach:**
```ruby
context = chat.build_context_for_agent(agent)  # Returns array of message hashes
llm.ask(context)  # WRONG: ask() treats array as message content, not history
```

Looking at RubyLLM's `ask` method:
```ruby
def ask(message = nil, with: nil, &)
  add_message role: :user, content: build_content(message, with)
  complete(&)
end
```

When called with an array, `ask` tries to pass it to `build_content` which expects a string or Content object. This doesn't properly set up the conversation history.

**Correct approach:**
```ruby
context = chat.build_context_for_agent(agent)  # Returns array of message hashes

llm = RubyLLM.chat(...)
# Add each context message individually
context.each { |msg| llm.add_message(msg) }
# Then call complete (not ask) to get the response
llm.complete { |chunk| ... }
```

The key insight is that RubyLLM's `complete` method already handles the tool call loop correctly (see lines 149-153 and 188-204 in ruby_llm/chat.rb). The problem is that `ask` wraps the context array incorrectly before calling `complete`.

## Solution

1. Modified both jobs to use `add_message` for each context message, then call `complete` directly
2. This preserves the tool call loop handling that RubyLLM already provides
3. Added `require "minitest/mock"` to test_helper.rb to enable stubbing in tests

## Implementation Checklist

- [x] Analyze root cause
- [x] Fix `ManualAgentResponseJob` to use add_message + complete pattern
- [x] Fix `AllAgentsResponseJob` to use add_message + complete pattern
- [x] Add minitest/mock to test_helper.rb for stubbing support
- [x] Write tests for ManualAgentResponseJob
- [x] Write tests for AllAgentsResponseJob
- [x] Run tests to verify the fix

## Files Modified

1. `/Users/danieltenner/dev/helix_kit/app/jobs/manual_agent_response_job.rb`
2. `/Users/danieltenner/dev/helix_kit/app/jobs/all_agents_response_job.rb`
3. `/Users/danieltenner/dev/helix_kit/test/test_helper.rb` (added require "minitest/mock")

## Files Created

1. `/Users/danieltenner/dev/helix_kit/test/jobs/manual_agent_response_job_test.rb`
2. `/Users/danieltenner/dev/helix_kit/test/jobs/all_agents_response_job_test.rb`

## Test Results

All 11 new tests pass:
- ManualAgentResponseJobTest: 5 tests
- AllAgentsResponseJobTest: 6 tests

Tests verify:
- Jobs are enqueued properly
- Context messages are added individually then complete is called
- Tool calls are handled and final responses are created
- Sequential processing works correctly (second agent sees first agent's response)
- Streaming cleanup on errors
