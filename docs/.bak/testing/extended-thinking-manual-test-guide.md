# Extended Thinking Feature - Manual Testing Guide

**Date**: 2026-01-01
**Feature**: Extended Thinking for AI Agents
**Implementation Plan**: `/docs/plans/260101-02c-thinking.md`

---

## Prerequisites

1. Development server is running on `http://localhost:3100`
2. Database migrations have been run successfully:
   - `agents.thinking_enabled` column exists
   - `agents.thinking_budget` column exists
   - `messages.thinking` column exists
3. You have login credentials:
   - Email: `daniel@granttree.co.uk`
   - Password: `password`

---

## Test Plan Overview

This guide provides step-by-step instructions for manually testing the Extended Thinking feature. Since automated browser testing via the `agent-browser` skill is not available, follow these manual test scenarios carefully.

---

## Test Scenario 1: Basic Agent Response (Baseline Test)

**Purpose**: Verify that the Test Agent can respond normally without Extended Thinking enabled.

### Steps:

1. **Login**
   - Navigate to `http://localhost:3100`
   - Enter email: `daniel@granttree.co.uk`
   - Enter password: `password`
   - Click "Sign in" or submit the form

2. **Navigate to Test Agent Chat**
   - Go directly to: `http://localhost:3100/accounts/gNDMev/chats/WjNywe`
   - OR: Click "Chats" in navigation, then find and click the Test Agent chat

3. **Send a Simple Message**
   - In the message input box at the bottom, type: `Hello, what's 2+2?`
   - Press Enter or click the send button (arrow up icon)

4. **Verify Response**
   - **Expected**: You should see a response from the agent within a few seconds
   - **Expected**: The response should answer the question (4)
   - **Expected**: No thinking block should appear (Extended Thinking is not enabled yet)
   - **Expected**: No errors in the browser console (press F12 to check)

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 2: Enable Extended Thinking for Claude Agent

**Purpose**: Enable Extended Thinking on the Claude agent (which uses Claude Opus 4.5, a thinking-capable model).

### Steps:

1. **Navigate to Agents Page**
   - Click "Agents" in the navbar (should open a dropdown)
   - Click "Identities" from the dropdown menu
   - You should see a list of agents

2. **Find and Edit the Claude Agent**
   - Look for an agent named "Claude" that uses "Claude Opus 4.5" model
   - Click on the agent card or edit button to open the edit page

3. **Verify Model Selection**
   - In the "AI Model" section, confirm the model is set to "Claude Opus 4.5" (anthropic/claude-opus-4.5)
   - This model should support Extended Thinking

4. **Enable Extended Thinking**
   - Scroll down to the "Extended Thinking" card
   - **Expected**: You should see a toggle switch for "Enable Thinking"
   - **Expected**: You should see text explaining "Show the model's reasoning process in responses"
   - **NOT Expected**: You should NOT see "The selected model does not support extended thinking"

5. **Turn on Extended Thinking**
   - Click the "Enable Thinking" toggle switch
   - **Expected**: The switch should turn on
   - **Expected**: A "Thinking Budget (tokens)" input field should appear below

6. **Set Thinking Budget**
   - **Expected**: The budget field should show default value of 10000
   - Optionally change it to 10000 if not already set
   - **Expected**: Minimum should be 1000, maximum 50000

7. **Save the Agent**
   - Click the "Save" or "Update Agent" button at the top or bottom
   - **Expected**: The page should update/reload showing the changes saved
   - **Expected**: The "Extended Thinking" section should still show thinking enabled

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 3: Test Extended Thinking with Claude Agent

**Purpose**: Send a complex question to Claude agent and verify thinking content appears.

### Steps:

1. **Navigate to a Chat with Claude Agent**
   - Go to Chats page
   - Either create a new chat with the Claude agent or open an existing one
   - Ensure the chat is using the Claude agent you just configured

2. **Send a Complex Question**
   - Type the following message:
     ```
     Explain step by step how you would solve: if x^2 + 3x - 4 = 0, what is x?
     ```
   - Send the message

3. **Observe the Streaming Response**
   - **Expected**: You should see a "thinking" indicator or spinner initially
   - **Expected**: A ThinkingBlock component should appear (collapsed by default)
   - **Expected**: The thinking block should have a Brain icon (may be pulsing/animated)
   - **Expected**: The preview text should show something like "Thinking..." or a truncated preview of the thinking content

4. **Wait for Thinking to Complete**
   - **Expected**: The thinking content should stream in (you may see the preview updating)
   - **Expected**: After thinking completes, the actual response should start streaming

5. **Verify ThinkingBlock Collapsed State**
   - **Expected**: The thinking block should be collapsed by default
   - **Expected**: It should show a preview (first ~80 characters of thinking)
   - **Expected**: It should show "Click to expand" text

6. **Expand the ThinkingBlock**
   - Click on the thinking block header/preview
   - **Expected**: The thinking block should expand with a sliding animation
   - **Expected**: You should see the full thinking content in a scrollable area
   - **Expected**: The content should be in monospace font (font-mono)
   - **Expected**: The text should say "Click to collapse" instead of "Click to expand"

7. **Collapse the ThinkingBlock**
   - Click the thinking block again
   - **Expected**: It should collapse back to preview mode

8. **Verify the Final Response**
   - **Expected**: Below the thinking block, there should be the actual response content
   - **Expected**: The response should explain the solution to the quadratic equation
   - **Expected**: The response should mention x = 1 and x = -4

9. **Reload the Page**
   - Refresh the browser (F5 or Cmd+R)
   - **Expected**: The message should still be there with thinking content preserved
   - **Expected**: The thinking block should be in collapsed state by default
   - **Expected**: Clicking it should expand and show the same thinking content

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 4: Enable and Test Extended Thinking for Gemini 3 Pro

**Purpose**: Verify Extended Thinking works with a different model provider (Google Gemini).

### Steps:

1. **Navigate to Agents Page**
   - Click "Agents" → "Identities" in navbar

2. **Find the Chris Agent (or another agent using Gemini 3 Pro)**
   - Look for an agent that uses "Gemini 3 Pro" model
   - If none exists, you may need to create one or change an existing agent's model

3. **Edit the Agent**
   - Open the agent edit page

4. **Change Model to Gemini 3 Pro (if needed)**
   - In the AI Model dropdown, select "Gemini 3 Pro" (google/gemini-3-pro-preview)
   - **Expected**: The Extended Thinking card should show that this model supports thinking

5. **Enable Extended Thinking**
   - Toggle "Enable Thinking" to ON
   - Set budget to 10000 (or any value between 1000-50000)
   - Click Save

6. **Send a Message to This Agent**
   - Navigate to or create a chat with this agent
   - Send a complex question like:
     ```
     Compare and contrast object-oriented programming with functional programming. What are the key differences?
     ```

7. **Verify Thinking Appears**
   - **Expected**: Similar behavior as Claude - thinking block should appear
   - **Expected**: Thinking content should stream and be displayed
   - **Expected**: The thinking block should be expandable/collapsible
   - **Expected**: Final response should appear after thinking

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 5: Model Without Thinking Support

**Purpose**: Verify that agents using non-thinking-capable models show appropriate UI.

### Steps:

1. **Navigate to Agents Page**
   - Click "Agents" → "Identities"

2. **Edit Any Agent or Create a New One**
   - Open the agent edit page

3. **Select a Non-Thinking Model**
   - Change the model to something like "Claude 3.5 Sonnet" or "GPT-4o"
   - These models do NOT support Extended Thinking according to the MODELS configuration

4. **Check Extended Thinking Section**
   - Scroll to the "Extended Thinking" card
   - **Expected**: You should see the message:
     ```
     The selected model does not support extended thinking.
     Choose Claude 4+, GPT-5, or Gemini 3 Pro to enable this feature.
     ```
   - **Expected**: The Enable Thinking toggle should NOT be visible
   - **Expected**: The Thinking Budget field should NOT be visible

5. **Try Switching to a Thinking-Capable Model**
   - Change the model back to "Claude Opus 4.5"
   - **Expected**: The thinking controls should become visible again

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 6: Error Handling - Missing Anthropic API Key

**Purpose**: Verify proper error handling when Anthropic API key is not configured (if applicable).

### Steps:

**Note**: This test only applies if your Anthropic API key is not configured. If it IS configured, skip this test.

1. **Check if Anthropic API Key is Configured**
   - Check Rails credentials or environment variables
   - If `ANTHROPIC_API_KEY` is set and valid, this test doesn't apply

2. **If API Key is Missing**:
   - Create/edit an agent with Claude Opus 4.5 and Extended Thinking enabled
   - Send a message to that agent
   - **Expected**: An error toast/message should appear saying something like:
     ```
     Extended thinking requires Anthropic API access, but the API key is not configured.
     ```
   - **Expected**: The error should be transient (disappear after ~5 seconds)
   - **Expected**: No permanent error message should be created in the chat

**Status**: ⬜ Pass / ⬜ Fail / ⬜ N/A (API key is configured)
**Notes**: ___________________________________________

---

## Test Scenario 7: Thinking Budget Validation

**Purpose**: Verify that thinking budget has proper min/max validation.

### Steps:

1. **Edit an Agent with Extended Thinking Enabled**
   - Go to agent edit page with a thinking-capable model selected
   - Enable thinking

2. **Test Minimum Validation**
   - Try to set thinking budget to 500 (below minimum of 1000)
   - Click Save
   - **Expected**: Should show validation error (either browser-side or after submit)
   - **Expected**: The agent should not save with invalid budget

3. **Test Maximum Validation**
   - Try to set thinking budget to 100000 (above maximum of 50000)
   - Click Save
   - **Expected**: Should show validation error
   - **Expected**: The agent should not save with invalid budget

4. **Test Valid Values**
   - Set budget to 1000 (minimum)
   - Click Save
   - **Expected**: Should save successfully
   - Set budget to 50000 (maximum)
   - Click Save
   - **Expected**: Should save successfully
   - Set budget to 20000 (middle range)
   - Click Save
   - **Expected**: Should save successfully

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 8: Browser Console Check

**Purpose**: Ensure there are no JavaScript errors during any operations.

### Steps:

1. **Open Browser Developer Tools**
   - Press F12 (Windows/Linux) or Cmd+Option+I (Mac)
   - Go to the "Console" tab

2. **Clear the Console**
   - Click the clear button (🚫 icon)

3. **Perform All Previous Tests Again**
   - Run through scenarios 1-7 again
   - Watch the console for any errors (red text)

4. **Check for Errors**
   - **Expected**: No JavaScript errors should appear (warnings are okay)
   - **Expected**: No failed network requests (check Network tab)
   - **Expected**: WebSocket connection should be established for real-time updates

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 9: Real-Time Streaming Updates

**Purpose**: Verify that thinking content streams in real-time.

### Steps:

1. **Send a Message Requiring Thinking**
   - Use an agent with Extended Thinking enabled
   - Send a complex question

2. **Watch the Thinking Block Closely**
   - **Expected**: The preview text should update as chunks arrive
   - **Expected**: If expanded, you should see a pulsing cursor (|) at the end while streaming
   - **Expected**: The Brain icon should pulse/animate while thinking is streaming

3. **Verify Streaming Transitions**
   - **Expected**: Thinking streams first
   - **Expected**: After thinking completes, content starts streaming
   - **Expected**: No overlap - thinking should finish before content starts

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Test Scenario 10: Multiple Messages with Thinking

**Purpose**: Verify thinking works correctly for multiple messages in a conversation.

### Steps:

1. **Send Multiple Messages**
   - Send 3-4 complex questions in a row to an agent with Extended Thinking
   - Examples:
     - "What is the Pythagorean theorem and how is it used?"
     - "Explain quantum entanglement in simple terms"
     - "How does photosynthesis work?"

2. **Verify Each Message**
   - **Expected**: Each response should have its own thinking block
   - **Expected**: Each thinking block should be independently expandable/collapsible
   - **Expected**: Thinking content should be unique to each message
   - **Expected**: Previous messages' thinking blocks should remain functional

**Status**: ⬜ Pass / ⬜ Fail
**Notes**: ___________________________________________

---

## Common Issues and Troubleshooting

### Issue: No Thinking Block Appears

**Possible Causes**:
1. Extended Thinking is not enabled on the agent
2. The model doesn't support thinking
3. API key issue (for Anthropic models)
4. Frontend component not rendering

**Debug Steps**:
1. Check agent edit page - verify thinking is enabled
2. Check browser console for errors
3. Check Rails logs for backend errors: `tail -f log/development.log`
4. Verify the message has `thinking` field in the database

### Issue: Thinking Block Doesn't Expand

**Possible Causes**:
1. JavaScript error preventing click handler
2. CSS issue hiding content

**Debug Steps**:
1. Check browser console for errors
2. Inspect the element to see if content is present but hidden
3. Try clicking different parts of the thinking block header

### Issue: Validation Errors When Saving Agent

**Possible Causes**:
1. Budget outside valid range (1000-50000)
2. Other agent field validation failures

**Debug Steps**:
1. Check all required fields are filled
2. Verify budget is a number between 1000 and 50000
3. Check browser console and Rails logs for specific validation errors

---

## Backend Verification (Optional)

If you have access to Rails console, you can verify the data:

```ruby
# Open Rails console
rails console

# Check agent thinking settings
agent = Agent.find_by(name: "Claude")
agent.thinking_enabled  # Should be true
agent.thinking_budget   # Should be 10000 or your set value
agent.uses_thinking?    # Should be true

# Check a message with thinking
message = Message.last
message.thinking        # Should contain thinking text
message.thinking_preview # Should be truncated version

# Check Chat model supports_thinking?
Chat.supports_thinking?("anthropic/claude-opus-4.5")  # Should be true
Chat.supports_thinking?("anthropic/claude-3.5-sonnet") # Should be false
```

---

## Test Results Summary

Fill in after completing all tests:

| Scenario | Status | Notes |
|----------|--------|-------|
| 1. Basic Agent Response | ⬜ Pass / ⬜ Fail | |
| 2. Enable Extended Thinking | ⬜ Pass / ⬜ Fail | |
| 3. Test Thinking with Claude | ⬜ Pass / ⬜ Fail | |
| 4. Test Thinking with Gemini | ⬜ Pass / ⬜ Fail | |
| 5. Non-Thinking Model | ⬜ Pass / ⬜ Fail | |
| 6. Error Handling | ⬜ Pass / ⬜ Fail / ⬜ N/A | |
| 7. Budget Validation | ⬜ Pass / ⬜ Fail | |
| 8. Console Check | ⬜ Pass / ⬜ Fail | |
| 9. Real-Time Streaming | ⬜ Pass / ⬜ Fail | |
| 10. Multiple Messages | ⬜ Pass / ⬜ Fail | |

**Overall Status**: ⬜ All Pass / ⬜ Some Failures
**Tester**: ___________
**Date**: ___________

---

## Next Steps After Testing

1. If all tests pass:
   - Mark the feature as complete
   - Consider creating automated Playwright tests for regression testing
   - Update documentation if needed

2. If tests fail:
   - Document the specific failure
   - Check implementation against plan: `/docs/plans/260101-02c-thinking.md`
   - Fix bugs in appropriate files
   - Re-run failing tests

3. Recommended follow-up:
   - Run Rails tests: `rails test`
   - Check for any test failures related to thinking
   - Consider adding integration tests for the thinking feature
