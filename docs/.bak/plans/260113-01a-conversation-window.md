# Conversation Window Implementation Plan

**Date:** 2026-01-13
**Feature:** Message Pagination with Scroll-to-Load
**Status:** Ready for Implementation

## Executive Summary

This plan addresses the performance and UX issues caused by very long conversations (150+ messages, 1.3M tokens). The solution implements cursor-based pagination that loads the most recent 30 messages initially, with additional batches loaded as the user scrolls upward. Token count warnings are added at 100k, 150k, and 200k thresholds to guide users toward starting new conversations.

## Architecture Overview

### Current State
- `ChatsController#show` loads ALL messages via `@messages = @chat.messages.includes(:user, :agent).with_attached_attachments.sorted`
- All messages are serialized as JSON and sent to the client
- Token count is calculated client-side from the loaded messages
- Real-time updates use ActionCable to trigger `router.reload({ only: ['messages'] })`

### Target State
- Controller loads only the most recent 30 messages by default
- Server provides total token count and pagination metadata
- Frontend detects scroll position near top and requests earlier messages
- Messages are prepended without scroll position disruption
- Token warnings appear at thresholds (amber at 100k, red at 150k, red header + suggestion at 200k)

### Key Design Decisions

1. **Cursor-based pagination** using `before_id` parameter rather than offset-based pagination
   - Messages are naturally ordered by `created_at`
   - Cursor avoids issues with messages being added while paginating
   - Uses obfuscated message IDs for security

2. **Server-side total token count** since we no longer have all messages client-side
   - Chat model already has `message_count`; add `total_tokens` method

3. **Incremental loading** preserves existing real-time sync pattern
   - New messages still append via ActionCable broadcasts
   - Loading older messages is a separate, user-triggered action

## Implementation Plan

### Phase 1: Backend Changes

#### 1.1 Add Token Aggregation to Chat Model

- [ ] Add `total_tokens` method to Chat model that sums all message tokens

```ruby
# app/models/chat.rb

def total_tokens
  messages.sum(:input_tokens) + messages.sum(:output_tokens)
end
```

- [ ] Add `total_tokens` to `json_attributes` declaration

```ruby
json_attributes :title_or_default, :model_id, :model_label, :ai_model_name,
                :updated_at_formatted, :updated_at_short, :message_count,
                :total_tokens, :web_access, :manual_responses, ...
```

#### 1.2 Add Message Pagination Scopes

- [ ] Add pagination scopes to Message model

```ruby
# app/models/message.rb

scope :before_message, ->(message_id) {
  where("id < ?", Message.decode_id(message_id)).order(created_at: :desc)
}

scope :recent_window, ->(limit = 30) {
  order(created_at: :desc).limit(limit)
}
```

#### 1.3 Update ChatsController#show

- [ ] Modify `show` action to support pagination

```ruby
# app/controllers/chats_controller.rb

def show
  # Same ordering as index: active first, then archived
  base_scope = current_account.chats
  active_chats = base_scope.kept.active.latest
  archived_chats = base_scope.kept.archived.latest
  @chats = active_chats + archived_chats

  # Paginate messages
  @messages = paginated_messages
  @has_more_messages = more_messages_available?
  @oldest_loaded_id = @messages.last&.to_param

  render inertia: "chats/show", props: {
    chat: chat_json_with_whiteboard,
    chats: @chats.map(&:as_json),
    messages: @messages.collect(&:as_json),
    pagination: messages_pagination,
    account: current_account.as_json,
    models: available_models,
    agents: @chat.group_chat? ? @chat.agents.as_json : [],
    available_agents: available_agents,
    file_upload_config: file_upload_config
  }
end

private

MESSAGES_PER_PAGE = 30

def paginated_messages
  scope = @chat.messages.includes(:user, :agent).with_attached_attachments

  if params[:before_id].present?
    # Loading older messages
    scope.before_message(params[:before_id]).limit(MESSAGES_PER_PAGE).reverse
  else
    # Initial load: get recent messages in correct order
    scope.recent_window(MESSAGES_PER_PAGE).reverse
  end
end

def more_messages_available?
  return false if @messages.empty?

  oldest_loaded = @messages.first
  @chat.messages.where("id < ?", oldest_loaded.id).exists?
end

def messages_pagination
  {
    has_more: @has_more_messages,
    oldest_loaded_id: @oldest_loaded_id,
    total_count: @chat.message_count,
    total_tokens: @chat.total_tokens,
    loaded_count: @messages.size
  }
end
```

#### 1.4 Add JSON Endpoint for Loading More Messages

- [ ] Add `messages` action to ChatsController for fetching older messages

```ruby
# app/controllers/chats_controller.rb

def messages
  @messages = paginated_messages
  @has_more_messages = more_messages_available?
  @oldest_loaded_id = @messages.last&.to_param

  render json: {
    messages: @messages.collect(&:as_json),
    pagination: messages_pagination
  }
end
```

- [ ] Add route for messages endpoint

```ruby
# config/routes.rb

resources :chats do
  member do
    get :messages  # Add this line
    post "trigger_agent/:agent_id", action: :trigger_agent, as: :trigger_agent
    # ... rest of member routes
  end
  resources :messages, only: :create
end
```

### Phase 2: Frontend Changes

#### 2.1 Update Props and State Management

- [ ] Update props destructuring to include pagination

```svelte
<!-- app/frontend/pages/chats/show.svelte -->

let {
  chat,
  chats = [],
  messages: initialMessages = [],
  pagination = {},
  account,
  models = [],
  agents = [],
  available_agents = [],
  file_upload_config = {},
} = $props();

// Local message state that can be mutated
let messages = $state(initialMessages);
let paginationState = $state(pagination);
let loadingMore = $state(false);
```

#### 2.2 Implement Scroll Detection

- [ ] Add scroll detection for loading more messages

```svelte
<script>
  // Scroll position tracking
  let previousScrollHeight = $state(0);
  let shouldPreserveScroll = $state(false);

  // Threshold for triggering load (pixels from top)
  const SCROLL_THRESHOLD = 200;

  function handleScroll() {
    if (!messagesContainer) return;

    const { scrollTop } = messagesContainer;

    // If near top and have more messages, load them
    if (scrollTop < SCROLL_THRESHOLD && paginationState.has_more && !loadingMore) {
      loadMoreMessages();
    }
  }

  async function loadMoreMessages() {
    if (loadingMore || !paginationState.has_more) return;

    loadingMore = true;
    shouldPreserveScroll = true;
    previousScrollHeight = messagesContainer?.scrollHeight || 0;

    try {
      const response = await fetch(
        `/accounts/${account.id}/chats/${chat.id}/messages?before_id=${paginationState.oldest_loaded_id}`,
        {
          headers: {
            'Accept': 'application/json',
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
          },
        }
      );

      if (response.ok) {
        const data = await response.json();

        // Prepend older messages
        messages = [...data.messages, ...messages];
        paginationState = data.pagination;
      }
    } catch (error) {
      logging.error('Failed to load more messages:', error);
    } finally {
      loadingMore = false;
    }
  }

  // Preserve scroll position after prepending messages
  $effect(() => {
    if (shouldPreserveScroll && messagesContainer) {
      const newScrollHeight = messagesContainer.scrollHeight;
      const scrollDelta = newScrollHeight - previousScrollHeight;
      messagesContainer.scrollTop += scrollDelta;
      shouldPreserveScroll = false;
    }
  });
</script>
```

#### 2.3 Update Messages Container

- [ ] Add scroll event listener to messages container

```svelte
<!-- Messages container -->
<div
  bind:this={messagesContainer}
  onscroll={handleScroll}
  class="flex-1 overflow-y-auto px-3 md:px-6 py-4 space-y-4"
>
  <!-- Loading more indicator -->
  {#if loadingMore}
    <div class="flex justify-center py-4">
      <Spinner size={24} class="animate-spin text-muted-foreground" />
    </div>
  {:else if paginationState.has_more}
    <div class="flex justify-center py-2">
      <button
        onclick={loadMoreMessages}
        class="text-sm text-muted-foreground hover:text-foreground"
      >
        Load earlier messages
      </button>
    </div>
  {/if}

  <!-- Rest of messages rendering... -->
</div>
```

#### 2.4 Implement Token Warnings

- [ ] Add token warning derived states and UI

```svelte
<script>
  // Token warning thresholds
  const TOKEN_WARNING_AMBER = 100_000;
  const TOKEN_WARNING_RED = 150_000;
  const TOKEN_WARNING_CRITICAL = 200_000;

  // Use server-provided total tokens
  const totalTokens = $derived(paginationState.total_tokens || 0);

  const tokenWarningLevel = $derived(() => {
    if (totalTokens >= TOKEN_WARNING_CRITICAL) return 'critical';
    if (totalTokens >= TOKEN_WARNING_RED) return 'red';
    if (totalTokens >= TOKEN_WARNING_AMBER) return 'amber';
    return null;
  });
</script>
```

- [ ] Update header to show token warnings

```svelte
<!-- Chat header -->
<header class="border-b border-border px-4 md:px-6 py-3 md:py-4"
        class:bg-red-50={tokenWarningLevel() === 'critical'}
        class:dark:bg-red-950/30={tokenWarningLevel() === 'critical'}
        class:bg-muted/30={tokenWarningLevel() !== 'critical'}>
  <div class="flex items-center gap-3">
    <!-- ... existing header content ... -->

    <div class="flex-1 min-w-0">
      <!-- Title section -->
      <!-- ... -->

      <div class="text-sm text-muted-foreground flex items-center gap-2">
        {#if chat?.manual_responses}
          <ParticipantAvatars {agents} {messages} />
          <span class="ml-2">{formatTokenCount(totalTokens)} tokens</span>
        {:else}
          {chat?.model_label || chat?.model_id || 'Auto'}
          <span class="ml-2 text-xs">({formatTokenCount(totalTokens)} tokens)</span>
        {/if}

        <!-- Token warning badges -->
        {#if tokenWarningLevel() === 'amber'}
          <Badge variant="outline" class="bg-amber-100 text-amber-800 border-amber-300 dark:bg-amber-900/30 dark:text-amber-400 dark:border-amber-700">
            Long conversation
          </Badge>
        {:else if tokenWarningLevel() === 'red'}
          <Badge variant="outline" class="bg-red-100 text-red-800 border-red-300 dark:bg-red-900/30 dark:text-red-400 dark:border-red-700">
            Very long conversation
          </Badge>
        {:else if tokenWarningLevel() === 'critical'}
          <Badge variant="destructive">
            Extremely long
          </Badge>
        {/if}
      </div>
    </div>

    <!-- ... rest of header ... -->
  </div>
</header>

<!-- Critical warning banner -->
{#if tokenWarningLevel() === 'critical'}
  <div class="bg-red-100 dark:bg-red-900/50 border-b border-red-200 dark:border-red-800 px-4 py-2 text-sm text-red-800 dark:text-red-200">
    <WarningCircle size={16} class="inline mr-2" weight="fill" />
    This conversation is very long ({formatTokenCount(totalTokens)} tokens). Consider
    <button onclick={forkConversation} class="underline font-medium hover:no-underline">
      forking
    </button> or starting a new conversation to maintain response quality.
  </div>
{/if}
```

#### 2.5 Update Real-time Sync for New Messages

- [ ] Ensure new messages append correctly with pagination

```svelte
<script>
  // Update sync effect to handle message count mismatch with pagination awareness
  $effect(() => {
    const subs = {};
    subs[`Account:${account.id}:chats`] = 'chats';

    if (chat) {
      subs[`Chat:${chat.id}`] = ['chat']; // Only reload chat, not messages
      subs[`Chat:${chat.id}:messages`] = 'messages';

      if (chat.active_whiteboard) {
        subs[`Whiteboard:${chat.active_whiteboard.id}`] = ['chat'];
      }
    }

    const messageSignature = Array.isArray(messages) ? messages.map((message) => message.id).join(':') : '';
    const nextSignature = `${account.id}|${chat?.id ?? 'none'}|${messageSignature}`;

    if (nextSignature !== syncSignature) {
      syncSignature = nextSignature;
      updateSync(subs);
    }

    // Only reload if the server's message count is higher than our loaded count
    // (meaning there are new messages, not just unloaded old ones)
    if (chat && messages.length > 0) {
      const mostRecentLoaded = messages[messages.length - 1];
      // New messages would have higher IDs, so we check if server count suggests new messages
      if (chat.message_count > paginationState.loaded_count + (paginationState.total_count - paginationState.loaded_count)) {
        logging.debug('Reloading: new messages detected');
        router.reload({
          only: ['messages', 'pagination', 'chat'],
          preserveState: true,
          preserveScroll: true,
        });
      }
    }
  });
</script>
```

#### 2.6 Handle Props Updates from Server

- [ ] Sync local state when props change (for real-time updates)

```svelte
<script>
  // When initialMessages prop changes (from server), update local state
  $effect(() => {
    // Only update if this is a fresh page load or reload, not during scroll loading
    if (!loadingMore && initialMessages.length > 0) {
      // Check if these are newer messages (real-time update) or a page reload
      const lastLocal = messages[messages.length - 1];
      const lastFromServer = initialMessages[initialMessages.length - 1];

      if (!lastLocal || lastFromServer?.id !== lastLocal?.id) {
        // Server has newer data - merge intelligently
        if (messages.length === 0) {
          messages = initialMessages;
        } else {
          // Append any new messages from server
          const existingIds = new Set(messages.map(m => m.id));
          const newMessages = initialMessages.filter(m => !existingIds.has(m.id));
          if (newMessages.length > 0) {
            messages = [...messages, ...newMessages];
          }
          // Update any existing messages (for streaming content)
          messages = messages.map(m => {
            const updated = initialMessages.find(im => im.id === m.id);
            return updated || m;
          });
        }
      }
    }
  });

  // Update pagination when it changes from server
  $effect(() => {
    if (pagination && !loadingMore) {
      paginationState = { ...paginationState, ...pagination };
    }
  });
</script>
```

### Phase 3: Route Generation

#### 3.1 Add Route Helper

- [ ] Generate route helper for messages endpoint

```javascript
// app/frontend/routes.js (or wherever routes are defined)

export function accountChatMessagesJsonPath(accountId, chatId, params = {}) {
  const url = `/accounts/${accountId}/chats/${chatId}/messages`;
  if (Object.keys(params).length > 0) {
    const searchParams = new URLSearchParams(params);
    return `${url}?${searchParams}`;
  }
  return url;
}
```

### Phase 4: Testing Strategy

#### 4.1 Controller Tests

- [ ] Add tests for pagination in ChatsController

```ruby
# test/controllers/chats_controller_test.rb

class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "show loads only recent messages by default" do
    chat = create_chat_with_messages(50)

    get account_chat_path(chat.account, chat)

    assert_response :success
    # Verify only 30 messages loaded
    props = parsed_inertia_props
    assert_equal 30, props[:messages].length
    assert props[:pagination][:has_more]
  end

  test "messages endpoint returns older messages with before_id" do
    chat = create_chat_with_messages(50)
    oldest_in_first_batch = chat.messages.recent_window(30).last

    get messages_account_chat_path(chat.account, chat, before_id: oldest_in_first_batch.to_param),
        headers: { 'Accept' => 'application/json' }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 20, json['messages'].length
    refute json['pagination']['has_more']
  end

  test "pagination includes total token count" do
    chat = create_chat_with_messages(10)

    get account_chat_path(chat.account, chat)

    props = parsed_inertia_props
    assert props[:pagination][:total_tokens].positive?
  end
end
```

#### 4.2 Model Tests

- [ ] Add tests for Message pagination scopes

```ruby
# test/models/message_test.rb

class MessageTest < ActiveSupport::TestCase
  test "before_message scope returns messages before given id" do
    chat = chats(:one)
    5.times { |i| chat.messages.create!(content: "Message #{i}", role: "user") }

    middle_message = chat.messages.order(:created_at)[2]
    earlier = chat.messages.before_message(middle_message.to_param)

    assert_equal 2, earlier.count
    assert earlier.all? { |m| m.id < middle_message.id }
  end

  test "recent_window returns most recent messages in reverse order" do
    chat = chats(:one)
    10.times { |i| chat.messages.create!(content: "Message #{i}", role: "user") }

    recent = chat.messages.recent_window(5)

    assert_equal 5, recent.count
    assert_equal chat.messages.order(created_at: :desc).first, recent.first
  end
end
```

#### 4.3 Integration Tests (Playwright)

- [ ] Add Playwright tests for scroll-to-load behavior

```javascript
// test/e2e/chat-pagination.spec.js

test('loads more messages when scrolling to top', async ({ page }) => {
  // Navigate to a chat with many messages
  await page.goto('/accounts/test/chats/long-conversation');

  // Verify initial load shows 30 messages
  const initialMessages = await page.locator('[data-message]').count();
  expect(initialMessages).toBeLessThanOrEqual(30);

  // Scroll to top
  await page.locator('[data-messages-container]').evaluate(el => el.scrollTop = 0);

  // Wait for more messages to load
  await page.waitForResponse(resp => resp.url().includes('/messages'));

  // Verify more messages loaded
  const afterScrollMessages = await page.locator('[data-message]').count();
  expect(afterScrollMessages).toBeGreaterThan(initialMessages);
});

test('shows token warning at 100k tokens', async ({ page }) => {
  // Navigate to a chat with many tokens
  await page.goto('/accounts/test/chats/high-token-chat');

  // Verify amber warning is shown
  await expect(page.locator('text=Long conversation')).toBeVisible();
});
```

## Edge Cases and Error Handling

### Edge Cases to Handle

1. **Empty conversations**: No messages to paginate
   - Show empty state, pagination returns `has_more: false`

2. **Very short conversations**: Less than 30 messages
   - Load all messages, `has_more: false`

3. **Message added during pagination**: User is loading older messages while new message arrives
   - New messages append via real-time sync; older messages prepend via pagination
   - These are independent operations that don't conflict

4. **Streaming message in progress**: Assistant is generating response
   - Streaming updates continue via existing ActionCable streaming sync
   - Scroll detection is disabled during streaming to avoid jarring UX

5. **Rapid scroll**: User scrolls very quickly through old messages
   - Debounce load requests to avoid multiple simultaneous requests
   - `loadingMore` flag prevents concurrent loads

### Error Handling

1. **Network failure when loading more**
   - Show subtle error message, allow retry
   - Keep existing messages intact

2. **Message deleted while displayed**
   - Real-time sync handles this via existing broadcast mechanisms

## Performance Considerations

1. **Database indexing**: `messages` table already has `index_messages_on_chat_id_and_created_at`
   - Pagination queries will be efficient

2. **Token count calculation**: `sum(:input_tokens) + sum(:output_tokens)`
   - Consider caching in Chat model if this becomes expensive
   - Counter cache could be added later if needed

3. **Memory usage**: Only 30 messages in memory at a time initially
   - Maximum grows as user scrolls but resets on page reload

## Migration Path

This feature is additive and backward-compatible:
- Existing chats will automatically use pagination
- No database migrations required (token aggregation uses existing columns)
- No data transformation needed

## Future Enhancements (Out of Scope)

1. **Message consolidation/summarization** at very high token counts
2. **Jump to specific message** functionality
3. **Search within conversation** with pagination
4. **Virtualized list rendering** for extremely long loaded histories

## Files to Modify

### Backend
- `/app/models/chat.rb` - Add `total_tokens` method and json_attribute
- `/app/models/message.rb` - Add pagination scopes
- `/app/controllers/chats_controller.rb` - Add pagination logic and messages endpoint
- `/config/routes.rb` - Add messages route

### Frontend
- `/app/frontend/pages/chats/show.svelte` - Major changes for pagination and token warnings
- `/app/frontend/routes.js` - Add route helper (if applicable)

### Tests
- `/test/controllers/chats_controller_test.rb`
- `/test/models/message_test.rb`
- `/test/e2e/chat-pagination.spec.js` (new file)

## Checklist Summary

- [ ] Add `total_tokens` method to Chat model
- [ ] Add `total_tokens` to Chat json_attributes
- [ ] Add `before_message` and `recent_window` scopes to Message model
- [ ] Update `ChatsController#show` with pagination
- [ ] Add `ChatsController#messages` JSON endpoint
- [ ] Add route for messages endpoint
- [ ] Update Svelte component with scroll detection
- [ ] Implement loadMoreMessages function
- [ ] Add scroll position preservation
- [ ] Implement token warning thresholds and UI
- [ ] Update real-time sync for pagination awareness
- [ ] Add controller tests
- [ ] Add model tests
- [ ] Add Playwright integration tests
