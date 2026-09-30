# Edit Last Message - Implementation Specification

**Plan ID:** 260113-02a
**Status:** Ready for Implementation
**Date:** January 13, 2026

## Summary

Allow users to edit their last message in a conversation before the AI responds. This is a simple typo-correction feature with clear constraints:

- Only the last user message can be edited
- Only when no AI response follows it yet
- Only by the user who posted it
- Uses a bottom drawer for the edit form (consistent with whiteboard pattern)

**Total new code: ~150 lines**

---

## 1. Overview

### User Stories

1. As a user, I want to quickly fix typos in my last message before the AI processes it
2. As a user, I want a simple way to access the edit function on both desktop and mobile
3. As a user, I want to cancel my edit without losing my original message

### Constraints

- Edit button only appears on the last user message when no AI response follows
- The edit button should be subtle (not distracting) but accessible
- Mobile-friendly: visible on mobile, hover-revealed on desktop
- Dark mode compatible

---

## 2. Backend Implementation

### Routes

**File:** `config/routes.rb`

Add update action to messages resource:

```ruby
resources :messages, only: [:create, :update]
```

Note: The update route will be nested under the standalone messages resource (like `retry`), not under chats, to simplify the frontend route generation.

Alternative (preferred for consistency with retry):

```ruby
resources :messages, only: [] do
  member do
    post :retry
    patch :update
  end
end
```

Actually, let's keep it RESTful and simple:

```ruby
resources :messages, only: [:update] do
  member do
    post :retry
  end
end
```

### Controller

**File:** `app/controllers/messages_controller.rb`

Add update action after retry:

```ruby
def update
  @message = current_account.chats.joins(:messages)
                            .where(messages: { id: params[:id] })
                            .first&.messages&.find(params[:id])

  return head :not_found unless @message
  return head :forbidden unless can_edit?(@message)

  if @message.update(message_params)
    respond_to do |format|
      format.html { redirect_to account_chat_path(@message.chat.account, @message.chat) }
      format.json { render json: @message, status: :ok }
    end
  else
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@message.chat.account, @message.chat), alert: "Failed to update message" }
      format.json { render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity }
    end
  end
end

private

def can_edit?(message)
  return false unless message.role == "user"
  return false unless message.user_id == Current.user.id
  return false if message_has_response?(message)
  true
end

def message_has_response?(message)
  message.chat.messages.where("created_at > ?", message.created_at).exists?
end
```

This approach:
- Uses association scoping for authorization (the Rails way)
- Checks user ownership
- Verifies no subsequent messages exist
- Returns appropriate HTTP status codes

---

## 3. Frontend Implementation

### Route Helper

After updating routes, run:

```bash
bin/rails js_from_routes:generate
```

This will generate `updateMessagePath(id)` in `app/frontend/routes/index.js`.

### State Management

**File:** `app/frontend/pages/chats/show.svelte`

Add to script section (near other state variables around line 170):

```javascript
// Edit message state
let editDrawerOpen = $state(false);
let editingMessage = $state(null);
let editContent = $state('');
let editSaving = $state(false);
```

Add derived state to determine if edit button should show (after `lastUserMessageNeedsResend`):

```javascript
// Check if last message can be edited (is user message with no response)
const canEditLastMessage = $derived(() => {
  if (!allMessages || allMessages.length === 0) return false;
  const lastMessage = allMessages[allMessages.length - 1];
  if (!lastMessage || lastMessage.role !== 'user') return false;
  // Only the author can edit
  if ($page.props.user?.id !== lastMessage.user_id) return false;
  // Can't edit if waiting for response (AI is processing)
  if (waitingForResponse) return false;
  return true;
});
```

### Edit Functions

Add after `resendLastMessage`:

```javascript
function startEditingMessage(message) {
  editingMessage = message;
  editContent = message.content || '';
  editDrawerOpen = true;
}

function cancelEditingMessage() {
  editDrawerOpen = false;
  editingMessage = null;
  editContent = '';
}

async function saveEditedMessage() {
  if (!editingMessage || editSaving) return;

  const trimmedContent = editContent.trim();
  if (!trimmedContent) {
    cancelEditingMessage();
    return;
  }

  editSaving = true;

  try {
    const response = await fetch(`/messages/${editingMessage.id}`, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
      },
      body: JSON.stringify({ message: { content: trimmedContent } }),
    });

    if (response.ok) {
      // Optimistically update the message in place
      const messageIndex = recentMessages.findIndex(m => m.id === editingMessage.id);
      if (messageIndex !== -1) {
        recentMessages = recentMessages.map((m, i) =>
          i === messageIndex ? { ...m, content: trimmedContent } : m
        );
      }
      cancelEditingMessage();
      // Reload to get proper markdown rendering from server
      router.reload({ only: ['messages'], preserveScroll: true });
    } else {
      const data = await response.json();
      errorMessage = data.errors?.[0] || 'Failed to update message';
      setTimeout(() => (errorMessage = null), 3000);
    }
  } catch (error) {
    errorMessage = 'Failed to update message';
    setTimeout(() => (errorMessage = null), 3000);
  } finally {
    editSaving = false;
  }
}
```

### Edit Button in Message Template

Modify the user message rendering (around line 1119-1160) to include edit button:

```svelte
{#if message.role === 'user'}
  <div class="flex justify-end">
    <div class="max-w-[85%] md:max-w-[70%]">
      <div class="group relative">
        <Card.Root class={getBubbleClass(message.author_colour)}>
          <Card.Content class="p-4">
            {#if message.files_json && message.files_json.length > 0}
              <div class="space-y-2 mb-3">
                {#each message.files_json as file}
                  <FileAttachment {file} onImageClick={openImageLightbox} />
                {/each}
              </div>
            {/if}
            <Streamdown
              content={message.content}
              parseIncompleteMarkdown
              baseTheme="shadcn"
              class="prose"
              animation={{
                enabled: true,
                type: 'fade',
                tokenize: 'word',
                duration: 300,
                timingFunction: 'ease-out',
                animateOnMount: false,
              }} />
          </Card.Content>
        </Card.Root>

        <!-- Edit button: visible on mobile for last editable message, hover on desktop -->
        {#if index === visibleMessages.length - 1 && canEditLastMessage()}
          <button
            onclick={() => startEditingMessage(message)}
            class="absolute -left-8 top-1/2 -translate-y-1/2 p-1.5 rounded-full
                   text-muted-foreground/50 hover:text-muted-foreground hover:bg-muted
                   transition-all duration-200
                   md:opacity-0 md:group-hover:opacity-100
                   focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring"
            title="Edit message"
            aria-label="Edit message">
            <PencilSimple size={14} weight="regular" />
          </button>
        {/if}
      </div>

      <div class="text-xs text-muted-foreground text-right mt-1">
        <!-- existing timestamp and resend button content -->
      </div>
    </div>
  </div>
{/if}
```

Note: `PencilSimple` is already imported (line 18 in show.svelte).

### Edit Drawer Component

Add after the whiteboard drawer (around line 1445):

```svelte
<!-- Edit Message Drawer -->
<Drawer.Root bind:open={editDrawerOpen} direction="bottom">
  <Drawer.Content class="max-h-[50vh]">
    <Drawer.Header class="sr-only">
      <Drawer.Title>Edit Message</Drawer.Title>
      <Drawer.Description>Edit your message content</Drawer.Description>
    </Drawer.Header>

    <div class="flex flex-col h-full">
      <div class="flex items-center justify-between px-4 py-3 border-b border-border">
        <h3 class="font-semibold">Edit Message</h3>
        <div class="flex items-center gap-2">
          <Button variant="outline" size="sm" onclick={cancelEditingMessage} disabled={editSaving}>
            <X class="mr-1 size-4" />
            Cancel
          </Button>
          <Button size="sm" onclick={saveEditedMessage} disabled={editSaving || !editContent.trim()}>
            {#if editSaving}
              <Spinner class="mr-1 size-4 animate-spin" />
            {:else}
              <FloppyDisk class="mr-1 size-4" />
            {/if}
            Save
          </Button>
        </div>
      </div>

      <div class="flex-1 p-4">
        <textarea
          bind:value={editContent}
          class="w-full h-full min-h-[120px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
                 focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent"
          placeholder="Edit your message..."
          disabled={editSaving}></textarea>
      </div>
    </div>
  </Drawer.Content>
</Drawer.Root>
```

---

## 4. UI/UX Specifications

### Desktop Behavior

- Edit button appears on hover over the last user message (when editable)
- Button positioned to the left of the message bubble
- Subtle opacity transition (0 -> 100% on hover)
- Keyboard accessible (visible on focus)

### Mobile Behavior

- Edit button always visible (but faint) on the last editable user message
- Same position (left of bubble)
- Lower opacity (50%) for subtlety

### Dark Mode

The implementation uses Tailwind's semantic colors:
- `text-muted-foreground/50` - subtle text color with 50% opacity
- `hover:bg-muted` - hover background
- `focus:ring-ring` - focus ring color

These automatically adapt to dark mode via the existing theme configuration.

### Drawer Behavior

- Opens from bottom (consistent with whiteboard)
- 50vh max height (compact for simple edits)
- Contains textarea with current message content
- Save and Cancel buttons in header
- Save button disabled when content is empty

---

## 5. Implementation Checklist

### Backend
- [ ] Add `update` action to `MessagesController`
- [ ] Add route for message update
- [ ] Run `bin/rails js_from_routes:generate`

### Frontend
- [ ] Add edit state variables
- [ ] Add `canEditLastMessage` derived state
- [ ] Add edit functions (`startEditingMessage`, `cancelEditingMessage`, `saveEditedMessage`)
- [ ] Modify user message template to include edit button
- [ ] Add edit drawer component

### Testing
- [ ] Controller test: successful edit
- [ ] Controller test: cannot edit other user's message
- [ ] Controller test: cannot edit message with response
- [ ] Controller test: cannot edit non-user message
- [ ] System test: edit button visibility (desktop hover)
- [ ] System test: complete edit flow

---

## 6. Testing Strategy

### Controller Tests

**File:** `test/controllers/messages_controller_test.rb`

```ruby
require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:confirmed_user)
    @chat = chats(:basic_chat)
    sign_in_as @user
  end

  test "can edit own last message with no response" do
    message = @chat.messages.create!(
      content: "Original content",
      role: "user",
      user: @user
    )

    patch message_path(message), params: { message: { content: "Edited content" } }, as: :json

    assert_response :ok
    assert_equal "Edited content", message.reload.content
  end

  test "cannot edit message from another user" do
    other_user = users(:other_user)
    message = @chat.messages.create!(
      content: "Other user message",
      role: "user",
      user: other_user
    )

    patch message_path(message), params: { message: { content: "Hacked!" } }, as: :json

    assert_response :forbidden
    assert_equal "Other user message", message.reload.content
  end

  test "cannot edit message when response exists" do
    message = @chat.messages.create!(
      content: "User message",
      role: "user",
      user: @user
    )

    @chat.messages.create!(
      content: "AI response",
      role: "assistant"
    )

    patch message_path(message), params: { message: { content: "Too late" } }, as: :json

    assert_response :forbidden
    assert_equal "User message", message.reload.content
  end

  test "cannot edit assistant message" do
    message = @chat.messages.create!(
      content: "AI message",
      role: "assistant"
    )

    patch message_path(message), params: { message: { content: "Modified" } }, as: :json

    assert_response :forbidden
  end
end
```

---

## 7. Code Summary

| Component | Lines | File |
|-----------|-------|------|
| Routes update | 2 | `config/routes.rb` |
| MessagesController#update | 35 | `app/controllers/messages_controller.rb` |
| Frontend state & functions | 50 | `app/frontend/pages/chats/show.svelte` |
| Edit button in template | 15 | `app/frontend/pages/chats/show.svelte` |
| Edit drawer component | 35 | `app/frontend/pages/chats/show.svelte` |
| Controller tests | 50 | `test/controllers/messages_controller_test.rb` |
| **Total** | **~185** | |

---

## 8. Security Considerations

- **Authorization**: Edit is scoped through `current_account.chats` association chain
- **Ownership check**: `message.user_id == Current.user.id`
- **Timing check**: No subsequent messages exist (prevents editing after AI sees the message)
- **CSRF protection**: Standard Rails CSRF token required for PATCH request

---

## 9. Edge Cases

| Scenario | Behavior |
|----------|----------|
| User clicks edit, AI responds before save | Save fails with forbidden (response now exists) |
| User clears content and saves | Edit cancelled, original content preserved |
| User in group chat edits | Only allowed if they're the author |
| Message has attachments | Attachments preserved (only content editable) |
| User on slow connection | Optimistic UI update, reverts on failure |
| Edit button clicked during streaming | Button should not appear during streaming |

---

## 10. Future Considerations (Out of Scope)

- Edit history/versioning
- Editing attachments
- Editing messages that already have responses (with cascade deletion)
- Undo functionality
- Keyboard shortcut for edit (e.g., up arrow like Slack)
