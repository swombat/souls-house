# Plan: Refactor chats/show.svelte into Focused Components

**Date:** 2026-02-21
**Status:** In Progress

## Problem

`app/frontend/pages/chats/show.svelte` is ~1,900 lines — a God Component with 8+ distinct responsibilities fused together. The `<script>` block alone is 1,183 lines. It handles chat messaging, real-time streaming, pagination, title editing, whiteboard management, message editing, file uploads, voice transcription, debug logging, Telegram banners, token warnings, agent assignment, moderation, and toast notifications.

## Target

Reduce `show.svelte` to ~300-400 lines that reads like a table of contents: receives page props, wires up real-time sync, manages top-level layout, and delegates everything to focused child components.

## Extraction Order (impact-to-effort ratio)

### Phase 1: WhiteboardDrawer.svelte
**Effort:** Low | **Impact:** ~160 lines removed | **Risk:** Near-zero

Completely self-contained. Has its own 5 state variables, own API calls, own conflict resolution UI. Shares only `chat.active_whiteboard`, `account.id`, `agentIsResponding`, and `shikiTheme` with the parent.

**Moves out:**
- Template: Lines 1738-1832 (Drawer.Root for whiteboard)
- State: `whiteboardOpen`, `whiteboardEditing`, `whiteboardEditContent`, `whiteboardConflict`, `whiteboardSaving`
- Functions: `saveWhiteboard`, `useServerVersion`, `keepMyVersion`, `startEditingWhiteboard`, `cancelEditingWhiteboard`

**Component location:** `app/frontend/lib/components/chat/WhiteboardDrawer.svelte`

**Props:**
```
open: $bindable(false)
whiteboard: object
accountId: string
agentIsResponding: boolean
shikiTheme: string
```

---

### Phase 2: ChatHeader.svelte
**Effort:** Medium | **Impact:** ~220 lines removed | **Risk:** Low

Self-contained visual region. Title display/editing, token warning badges, dropdown menu with all chat actions.

**Moves out:**
- Template: Lines 1202-1339 (header element)
- State: `titleEditing`, `titleEditValue`, `titleInputRef`, `originalTitle`
- Derived: `tokenWarningLevel`, `headerClass`, `titleIsLoading`, `isSiteAdmin`, `isAccountAdmin`, `canDeleteChat`
- Functions: `startEditingTitle`, `cancelEditingTitle`, `saveTitle`, `handleTitleKeydown`, `handleTitleBlur`, `handleTitleClick`, `handleTitleDoubleClick`, `toggleWebAccess`, `forkConversation`, `archiveChat`, `deleteChat`, `moderateAllMessages`

**Component location:** `app/frontend/lib/components/chat/ChatHeader.svelte`

**Props:**
```
chat: object
account: object
agents: array
allMessages: array
totalTokens: number
thresholds: object
availableAgents: array
addableAgents: array
isSiteAdmin: boolean
isAccountAdmin: boolean
agentIsResponding: boolean
showAllMessages: $bindable(false)
debugMode: $bindable(false)
onsidebaropen: function
onassignagent: function
onaddagent: function
onwhiteboardopen: function
onerror: function
onsuccess: function
```

---

### Phase 3: MessageBubble.svelte
**Effort:** Medium-High | **Impact:** ~130 lines of template removed | **Risk:** Medium

The per-message rendering for both user and assistant bubbles. The `{#each}` body becomes a component call.

**Moves out:**
- Template: Lines 1447-1608 (inside the `{#each}` block)
- Utility functions: `getBubbleClass`, `formatToolsUsed` → move to chat-utils.js

**Component location:** `app/frontend/lib/components/chat/MessageBubble.svelte`

**Props:**
```
message: object
isLastVisible: boolean
isGroupChat: boolean
showResend: boolean
streamingThinking: string
shikiTheme: string
onedit: function
ondelete: function
onretry: function
onfix: function
onresend: function
onimagelightbox: function
```

---

### Phase 4: MessageComposer.svelte
**Effort:** Medium | **Impact:** ~80 lines removed | **Risk:** Low-Medium

The input area: textarea, file upload, mic button, send button. Encapsulates form state, auto-resize, keydown handling, and the send action.

**Moves out:**
- Template: Lines 1692-1734
- State: `messageInput`, `selectedFiles`, `submitting`, `pendingAudioSignedId`, `textareaRef`, `placeholder`
- Functions: `sendMessage`, `handleTranscription`, `handleTranscriptionError`, `handleKeydown`, `autoResize`
- Form: `messageForm`

**Component location:** `app/frontend/lib/components/chat/MessageComposer.svelte`

**Props:**
```
accountId: string
chatId: string
disabled: boolean
respondable: boolean
manualResponses: boolean
fileUploadConfig: object
onsent: function (callback when message sent successfully, for sync refresh + agent prompt)
onerror: function
```

---

### Phase 5: EditMessageDrawer.svelte
**Effort:** Low | **Impact:** ~50 lines removed | **Risk:** Near-zero

Trivially self-contained message editing drawer.

**Moves out:**
- Template: Lines 1834-1859
- State: `editDrawerOpen`, `editingMessageId`, `editingContent`, `editSaving`
- Functions: `startEditingMessage`, `cancelEditingMessage`, `saveEditedMessage`

**Component location:** `app/frontend/lib/components/chat/EditMessageDrawer.svelte`

**Props:**
```
open: $bindable(false)
messageId: string
initialContent: string
onSaved: function (callback to update local message state + reload)
onerror: function
```

---

### Phase 6: Utility Extractions + Bug Fixes
**Effort:** Low | **Impact:** Cleaner code throughout | **Risk:** Near-zero

**6a. `$lib/chat-utils.js`** — Pure utility functions:
- `csrfToken()` — replaces 5 duplicated `document.querySelector(...)` calls
- `formatToolsUsed(toolsUsed)`
- `formatTokenCount(count)`
- `getBubbleClass(colour)`
- `flashError(setter, message, duration)` — replaces 7 duplicated setTimeout patterns

**6b. Fix `$derived` vs `$derived.by` bug** — Lines 394, 409, 434, 453, 463, 469 use `$derived(() => {...})` which returns functions instead of values. Change to `$derived.by()`.

---

### Phase 7: Small Component Extractions
**Effort:** Low each | **Impact:** ~60 lines total | **Risk:** Near-zero

- **`TelegramBanner.svelte`** (~30 lines) — Has own localStorage logic and dismiss state
- **`DebugPanel.svelte`** (~30 lines) — Admin-only debug panel with own log state
- **`ToastNotification.svelte`** (~15 lines) — Replaces duplicated error/success toast markup

**Component locations:** All in `app/frontend/lib/components/chat/`

---

## Testing Strategy

After each phase:
1. Use `agent-browser` to verify the chat page still renders correctly
2. Verify messages display, sending works, and extracted feature works
3. Move to next phase only after confirmation

## Expected Final State

`show.svelte` should be ~300-400 lines:
- Props destructuring
- Real-time sync setup (createDynamicSync, streamingSync)
- Message pagination state + loadMoreMessages
- Derived message lists (allMessages, visibleMessages)
- Layout: ChatList sidebar + main area with composed components
- All rendering delegated to child components
