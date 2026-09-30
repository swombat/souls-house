# Remove Title Generation Blocking

## Problem
Currently, when a new chat is created, the UI is completely frozen while the title is being generated. This prevents users from:
- Continuing the conversation
- Triggering agent responses (in group chats)
- Using the chat normally

The blocking happens because `chatIsInitializing` (line 194) checks if there's no title but messages exist, and this state:
- Shows "Setting up..." with a spinner in the header (lines 664-666)
- Disables the AgentTriggerBar for group chats (line 967)

## Solution
Title generation is cosmetic and shouldn't block actual functionality. We need to:

1. Remove `chatIsInitializing` from the disabled condition on AgentTriggerBar
2. Update the header to show a subtle loading state for the title only (not blocking "Setting up..." text)
3. Allow all chat functionality to work normally while title loads

## Implementation Tasks

- [x] Rename `chatIsInitializing` to `titleIsLoading` with updated comment (line 200)
- [x] Remove `titleIsLoading` from AgentTriggerBar disabled condition (line 1070)
- [x] Update header to show subtle inline spinner next to title while loading (lines 764-766)
- [x] Verify the changes compile and look correct

## Files Modified

- `/Users/danieltenner/dev/helix_kit/app/frontend/pages/chats/show.svelte` - Removed blocking behavior and updated UI

## Changes Made

1. **Line 200**: Renamed `chatIsInitializing` to `titleIsLoading` with clearer comment explaining it's cosmetic only
2. **Lines 758-767**: Updated header to show inline spinner next to title when loading (not blocking text)
3. **Line 1070**: Removed `titleIsLoading` from AgentTriggerBar disabled condition - now only disabled by `agentIsResponding`

## Testing

Manual testing needed:
1. Create a new chat and send a message
2. Verify you can immediately send another message (don't need to wait for title)
3. For group chats, verify you can trigger agents immediately
4. Verify the title loading spinner shows inline next to "New Chat" and doesn't block the UI
5. Verify the spinner disappears when title is generated

## Summary

The title generation is now purely cosmetic. Users can:
- Continue chatting normally while the title loads
- Trigger agent responses in group chats immediately
- See a subtle spinner next to the title indicating it's loading
- Use all chat functionality without being blocked

This improves the user experience by removing unnecessary blocking behavior.
