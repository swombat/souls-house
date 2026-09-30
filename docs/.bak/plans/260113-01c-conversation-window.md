# Conversation Window Implementation Plan (Final)

**Date:** 2026-01-13
**Feature:** Message Pagination with Scroll-to-Load
**Status:** Phase 1 & 2 Complete - Ready for Phase 3 (Frontend)
**Revision:** C (final, incorporates all DHH feedback)

## Executive Summary

Load the most recent 30 messages initially, with additional batches loaded as the user scrolls upward. Token count warnings appear at 100k, 150k, and 200k thresholds. This final revision eliminates unnecessary abstractions, moves pagination logic to the model, clearly separates Inertia-managed state from local pagination state, and incorporates all minor refinements from DHH review.

## Architecture Overview

### Key Design Principles

1. **Fat model, skinny controller** - Pagination lives in `Chat#messages_page`
2. **Clear state separation** - Inertia manages recent messages; local state manages historical loads
3. **Single source of truth** - Token thresholds shared via `inertia_share`
4. **Simple scroll preservation** - `requestAnimationFrame`, not reactive state
5. **Trust existing patterns** - ActionCable handles new messages; pagination handles old ones
6. **No single-use abstractions** - Inline logic that serves only one call site

### Current State
- `ChatsController#show` loads ALL messages
- Token count calculated client-side from loaded messages
- Real-time updates via ActionCable trigger `router.reload({ only: ['messages'] })`

### Target State
- Controller delegates to `Chat#messages_page(before_id:, limit:)`
- Server provides `has_more_messages` and `oldest_message_id`
- Frontend maintains separate `olderMessages` array for paginated history
- Token thresholds come from server via `inertia_share`

## Implementation Order

Follow this sequence to catch backend bugs before they cascade to the frontend:

1. **Backend first**: Model methods, controller updates, routes, inertia_share
2. **Backend tests second**: Verify pagination works before touching frontend
3. **Frontend third**: State management, scroll detection, token warnings
4. **Playwright tests last**: Verify the integration works end-to-end

## Implementation Plan

### Phase 1: Backend Changes (COMPLETE)

#### 1.1 Add Pagination Method to Chat Model

- [x] Add `messages_page` method to Chat model (inline the before logic, no separate scope)

```ruby
# app/models/chat.rb

def messages_page(before_id: nil, limit: 30)
  scope = messages.includes(:user, :agent).with_attached_attachments
  scope = scope.where("messages.id < ?", Message.decode_id(before_id)) if before_id.present?
  # Use reorder to replace any existing ordering (from acts_as_chat),
  # get the most recent messages by ordering by ID DESC, limit, then reverse for display
  scope.reorder(id: :desc).limit(limit).reverse
end

def total_tokens
  messages.sum("COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)")
end
```

- [x] Add `total_tokens` to `json_attributes`

```ruby
json_attributes :title_or_default, :model_id, :model_label, :ai_model_name,
                :updated_at_formatted, :updated_at_short, :message_count,
                :total_tokens, :web_access, :manual_responses, ...
```

#### 1.2 Update ChatsController#show

- [x] Modify `show` action to use pagination

```ruby
# app/controllers/chats_controller.rb

def show
  base_scope = current_account.chats
  active_chats = base_scope.kept.active.latest
  archived_chats = base_scope.kept.archived.latest
  @chats = active_chats + archived_chats

  @messages = @chat.messages_page
  @has_more = @messages.any? && @chat.messages.where("id < ?", @messages.first.id).exists?

  render inertia: "chats/show", props: {
    chat: chat_json_with_whiteboard,
    chats: @chats.map(&:as_json),
    messages: @messages.collect(&:as_json),
    has_more_messages: @has_more,
    oldest_message_id: @messages.first&.to_param,
    account: current_account.as_json,
    models: available_models,
    agents: @chat.group_chat? ? @chat.agents.as_json : [],
    available_agents: available_agents,
    file_upload_config: file_upload_config
  }
end
```

#### 1.3 Add JSON Endpoint for Older Messages

- [x] Add `older_messages` action to ChatsController

```ruby
# app/controllers/chats_controller.rb

def older_messages
  @messages = @chat.messages_page(before_id: params[:before_id])
  @has_more = @messages.any? && @chat.messages.where("id < ?", @messages.first.id).exists?

  render json: {
    messages: @messages.collect(&:as_json),
    has_more: @has_more,
    oldest_id: @messages.first&.to_param
  }
end
```

- [x] Add route for older_messages endpoint

```ruby
# config/routes.rb

resources :chats do
  member do
    get :older_messages
    post "trigger_agent/:agent_id", action: :trigger_agent, as: :trigger_agent
    # ... existing routes
  end
  resources :messages, only: :create
end
```

#### 1.4 Share Token Thresholds via ApplicationController

- [x] Add token thresholds to `inertia_share`

```ruby
# app/controllers/application_controller.rb

inertia_share do
  if authenticated?
    {
      user: Current.user.as_json,
      account: current_account&.as_json,
      accounts: Current.user.accounts.map(&:as_json),
      theme_preference: Current.user&.theme || cookies[:theme],
      site_settings: shared_site_settings,
      is_account_admin: current_account&.manageable_by?(Current.user) || false,
      token_thresholds: { amber: 100_000, red: 150_000, critical: 200_000 }
    }
  else
    {
      theme_preference: cookies[:theme],
      site_settings: shared_site_settings
    }
  end
end
```

### Phase 2: Backend Tests (COMPLETE)

#### 2.1 Model Tests

- [x] Add tests for Chat pagination methods

All tests added to `/test/models/chat_test.rb`:
- `test_messages_page_returns_limited_messages`
- `test_messages_page_returns_messages_in_ascending_order_for_display`
- `test_messages_page_with_before_id_returns_older_messages`
- `test_messages_page_returns_empty_when_before_id_is_first_message`
- `test_messages_page_default_limit_is_30`
- `test_total_tokens_sums_input_and_output_tokens`
- `test_total_tokens_handles_nil_values`
- `test_total_tokens_returns_zero_for_chat_with_no_messages`
- `test_total_tokens_sums_all_message_tokens_correctly`
- `test_as_json_includes_total_tokens`

#### 2.2 Controller Tests

- [x] Add tests for ChatsController pagination

All tests added to `/test/controllers/chats_controller_test.rb`:
- `test_older_messages_returns_JSON_with_pagination_info`
- `test_older_messages_returns_messages_before_specified_ID`
- `test_older_messages_returns_empty_when_no_more_messages`
- `test_older_messages_requires_authentication`
- `test_older_messages_scopes_to_current_account`
- `test_older_messages_indicates_has_more_correctly_when_more_messages_exist`
- `test_older_messages_indicates_has_more_false_when_no_more_messages`

### Phase 3: Frontend Changes

#### 3.1 Update Props and State Management

- [ ] Update state management in show.svelte

```svelte
<script>
  let {
    chat,
    chats = [],
    messages: recentMessages = [],
    has_more_messages: serverHasMore = false,
    oldest_message_id: serverOldestId = null,
    account,
    models = [],
    agents = [],
    available_agents = [],
    file_upload_config = {},
  } = $props();

  // Older messages loaded via pagination (not managed by Inertia)
  let olderMessages = $state([]);
  let hasMore = $state(serverHasMore);
  let oldestId = $state(serverOldestId);
  let loadingMore = $state(false);

  // Combined messages for display
  const allMessages = $derived([...olderMessages, ...recentMessages]);

  // Token thresholds from server
  const thresholds = $derived($page.props.token_thresholds || { amber: 100_000, red: 150_000, critical: 200_000 });

  // Use server-provided total tokens from chat
  const totalTokens = $derived(chat?.total_tokens || 0);

  // Direct ternary expression, not a function
  const tokenWarningLevel = $derived(
    totalTokens >= thresholds.critical ? 'critical' :
    totalTokens >= thresholds.red ? 'red' :
    totalTokens >= thresholds.amber ? 'amber' : null
  );

  // Explicit chat reset tracking
  let previousChatId = null;

  $effect(() => {
    if (chat?.id !== previousChatId) {
      previousChatId = chat?.id;
      olderMessages = [];
      hasMore = serverHasMore;
      oldestId = serverOldestId;
    }
  });

  // Update pagination state when server props change (only when not loading)
  $effect(() => {
    if (!loadingMore) {
      hasMore = serverHasMore;
      oldestId = serverOldestId;
    }
  });
</script>
```

#### 3.2 Implement Scroll Detection and Loading

- [ ] Add scroll detection with simple scroll preservation

```svelte
<script>
  const SCROLL_THRESHOLD = 200;

  function handleScroll() {
    if (!messagesContainer) return;
    if (messagesContainer.scrollTop < SCROLL_THRESHOLD && hasMore && !loadingMore) {
      loadMoreMessages();
    }
  }

  async function loadMoreMessages() {
    if (loadingMore || !hasMore || !oldestId) return;

    loadingMore = true;
    const container = messagesContainer;
    const previousHeight = container.scrollHeight;

    try {
      const response = await fetch(
        `/accounts/${account.id}/chats/${chat.id}/older_messages?before_id=${oldestId}`,
        {
          headers: {
            'Accept': 'application/json',
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
          },
        }
      );

      if (response.ok) {
        const data = await response.json();
        olderMessages = [...data.messages, ...olderMessages];
        hasMore = data.has_more;
        oldestId = data.oldest_id;

        // Simple scroll preservation with requestAnimationFrame
        requestAnimationFrame(() => {
          container.scrollTop += container.scrollHeight - previousHeight;
        });
      }
    } catch (error) {
      logging.error('Failed to load more messages:', error);
    } finally {
      loadingMore = false;
    }
  }
</script>
```

#### 3.3 Update Messages Container

- [ ] Add scroll event listener and loading indicator

```svelte
<div
  bind:this={messagesContainer}
  onscroll={handleScroll}
  class="flex-1 overflow-y-auto px-3 md:px-6 py-4 space-y-4"
>
  {#if loadingMore}
    <div class="flex justify-center py-4">
      <Spinner size={24} class="animate-spin text-muted-foreground" />
    </div>
  {:else if hasMore}
    <div class="flex justify-center py-2">
      <button
        onclick={loadMoreMessages}
        class="text-sm text-muted-foreground hover:text-foreground"
      >
        Load earlier messages
      </button>
    </div>
  {/if}

  <!-- Use allMessages instead of messages -->
  {#each visibleMessages as message, index (message.id)}
    <!-- existing message rendering -->
  {/each}
</div>
```

#### 3.4 Update visibleMessages Derived

- [ ] Change to use `allMessages`

```svelte
<script>
  const visibleMessages = $derived(
    showToolCalls
      ? allMessages
      : allMessages.filter((m) => {
          if (m.role === 'tool') return false;
          if (m.role === 'assistant' && (!m.content || m.content.trim() === '') && !m.streaming) return false;
          if (m.role === 'assistant' && m.content && m.content.trim().startsWith('{') && !m.streaming) return false;
          return true;
        })
  );
</script>
```

#### 3.5 Implement Token Warnings

- [ ] Update header with warning styles and badges (note: no parentheses on tokenWarningLevel)

```svelte
<header
  class="border-b border-border px-4 md:px-6 py-3 md:py-4"
  class:bg-red-50={tokenWarningLevel === 'critical'}
  class:dark:bg-red-950/30={tokenWarningLevel === 'critical'}
  class:bg-muted/30={tokenWarningLevel !== 'critical'}
>
  <div class="flex items-center gap-3">
    <!-- existing content -->
    <div class="flex-1 min-w-0">
      <!-- title section unchanged -->
      <div class="text-sm text-muted-foreground flex items-center gap-2 flex-wrap">
        {#if chat?.manual_responses}
          <ParticipantAvatars {agents} messages={allMessages} />
          <span class="ml-2">{formatTokenCount(totalTokens)} tokens</span>
        {:else}
          {chat?.model_label || chat?.model_id || 'Auto'}
          <span class="ml-2 text-xs">({formatTokenCount(totalTokens)} tokens)</span>
        {/if}

        {#if tokenWarningLevel === 'amber'}
          <Badge variant="outline" class="bg-amber-100 text-amber-800 border-amber-300 dark:bg-amber-900/30 dark:text-amber-400 dark:border-amber-700">
            Long conversation
          </Badge>
        {:else if tokenWarningLevel === 'red'}
          <Badge variant="outline" class="bg-red-100 text-red-800 border-red-300 dark:bg-red-900/30 dark:text-red-400 dark:border-red-700">
            Very long
          </Badge>
        {:else if tokenWarningLevel === 'critical'}
          <Badge variant="destructive">
            Extremely long
          </Badge>
        {/if}
      </div>
    </div>
    <!-- rest of header -->
  </div>
</header>

{#if tokenWarningLevel === 'critical'}
  <div class="bg-red-100 dark:bg-red-900/50 border-b border-red-200 dark:border-red-800 px-4 py-2 text-sm text-red-800 dark:text-red-200">
    <WarningCircle size={16} class="inline mr-2" weight="fill" />
    This conversation is very long ({formatTokenCount(totalTokens)} tokens). Consider
    <button onclick={forkConversation} class="underline font-medium hover:no-underline">
      forking
    </button> or starting a new conversation.
  </div>
{/if}
```

#### 3.6 Simplify Sync Logic

- [ ] Remove message count comparison from sync effect

```svelte
<script>
  // Set up real-time subscriptions - SIMPLIFIED
  $effect(() => {
    const subs = {};
    subs[`Account:${account.id}:chats`] = 'chats';

    if (chat) {
      subs[`Chat:${chat.id}`] = ['chat', 'messages'];
      subs[`Chat:${chat.id}:messages`] = 'messages';

      if (chat.active_whiteboard) {
        subs[`Whiteboard:${chat.active_whiteboard.id}`] = ['chat', 'messages'];
      }
    }

    const messageSignature = Array.isArray(recentMessages) ? recentMessages.map((m) => m.id).join(':') : '';
    const nextSignature = `${account.id}|${chat?.id ?? 'none'}|${messageSignature}`;

    if (nextSignature !== syncSignature) {
      syncSignature = nextSignature;
      updateSync(subs);
    }
    // ActionCable broadcasts handle new messages automatically
  });
</script>
```

### Phase 4: Integration Tests (Playwright)

- [ ] Add Playwright tests for scroll-to-load behavior

```javascript
// test/e2e/chat-pagination.spec.js

test('loads more messages when scrolling to top', async ({ page }) => {
  // Setup: navigate to chat with many messages
  await page.goto('/accounts/test/chats/long-conversation');

  // Initial load should show limited messages
  const initialCount = await page.locator('[data-message]').count();
  expect(initialCount).toBeLessThanOrEqual(30);

  // Scroll to top
  await page.locator('[data-messages-container]').evaluate(el => el.scrollTop = 0);

  // Wait for load more to trigger
  await page.waitForResponse(resp => resp.url().includes('/older_messages'));

  // More messages should be loaded
  const afterCount = await page.locator('[data-message]').count();
  expect(afterCount).toBeGreaterThan(initialCount);
});

test('shows token warning badges at thresholds', async ({ page }) => {
  // Chat with >100k tokens should show amber warning
  await page.goto('/accounts/test/chats/high-token-chat');
  await expect(page.locator('text=Long conversation')).toBeVisible();
});

test('critical warning shows red header and banner', async ({ page }) => {
  // Chat with >200k tokens
  await page.goto('/accounts/test/chats/very-high-token-chat');

  // Header should have red background class
  await expect(page.locator('header.bg-red-50')).toBeVisible();

  // Warning banner should be visible
  await expect(page.locator('text=Consider forking')).toBeVisible();
});
```

## Files Modified

### Backend (COMPLETE)
- `/app/models/chat.rb` - Added `messages_page` and `total_tokens` methods, added `total_tokens` to json_attributes
- `/app/controllers/chats_controller.rb` - Updated `show`, added `older_messages`
- `/app/controllers/application_controller.rb` - Added `token_thresholds` to `inertia_share`
- `/config/routes.rb` - Added `older_messages` route

### Tests (COMPLETE)
- `/test/models/chat_test.rb` - Added pagination and total_tokens tests
- `/test/controllers/chats_controller_test.rb` - Added older_messages endpoint tests

### Frontend (NOT STARTED)
- `/app/frontend/pages/chats/show.svelte` - Pagination state, scroll detection, token warnings

### Integration Tests (NOT STARTED)
- `/test/e2e/chat-pagination.spec.js` (new file)

## Implementation Notes

### Key Change from Original Spec

The `messages_page` method uses `reorder(id: :desc)` instead of `order(id: :desc)` because the `acts_as_chat` macro from RubyLLM adds a default ordering to the messages association. Using `reorder` replaces the existing order clause entirely, ensuring we get the most recent messages first.

## Checklist Summary

### Phase 1: Backend (COMPLETE)
- [x] Add `messages_page(before_id:, limit:)` to Chat model (with inlined before logic)
- [x] Add `total_tokens` to Chat model using single SQL query
- [x] Add `total_tokens` to Chat json_attributes
- [x] Update `ChatsController#show` with pagination
- [x] Add `ChatsController#older_messages` JSON endpoint
- [x] Add route for `older_messages`
- [x] Add `token_thresholds` to ApplicationController inertia_share

### Phase 2: Backend Tests (COMPLETE)
- [x] Add model tests for pagination
- [x] Add controller tests for both endpoints

### Phase 3: Frontend (NOT STARTED)
- [ ] Update Svelte: separate `olderMessages` state
- [ ] Update Svelte: `allMessages` derived combining both
- [ ] Update Svelte: scroll detection with `requestAnimationFrame`
- [ ] Update Svelte: `tokenWarningLevel` as direct ternary (no arrow function)
- [ ] Update Svelte: explicit `previousChatId` tracking for chat reset
- [ ] Update Svelte: token warnings from server thresholds (no parentheses)
- [ ] Remove message count comparison from sync logic

### Phase 4: Integration Tests (NOT STARTED)
- [ ] Add Playwright integration tests
