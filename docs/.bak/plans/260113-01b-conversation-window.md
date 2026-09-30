# Conversation Window Implementation Plan (Revised)

**Date:** 2026-01-13
**Feature:** Message Pagination with Scroll-to-Load
**Status:** Ready for Implementation
**Revision:** B (incorporates DHH feedback)

## Executive Summary

Load the most recent 30 messages initially, with additional batches loaded as the user scrolls upward. Token count warnings appear at 100k, 150k, and 200k thresholds. This revision eliminates unnecessary abstractions, moves pagination logic to the model, and clearly separates Inertia-managed state from local pagination state.

## Architecture Overview

### Key Design Principles (DHH Feedback Applied)

1. **Fat model, skinny controller** - Pagination lives in `Chat#messages_page`
2. **Clear state separation** - Inertia manages recent messages; local state manages historical loads
3. **Single source of truth** - Token thresholds shared via `inertia_share`
4. **Simple scroll preservation** - `requestAnimationFrame`, not reactive state
5. **Trust existing patterns** - ActionCable handles new messages; pagination handles old ones

### Current State
- `ChatsController#show` loads ALL messages
- Token count calculated client-side from loaded messages
- Real-time updates via ActionCable trigger `router.reload({ only: ['messages'] })`

### Target State
- Controller delegates to `Chat#messages_page(before_id:, limit:)`
- Server provides `has_more_messages` and `oldest_message_id`
- Frontend maintains separate `olderMessages` array for paginated history
- Token thresholds come from server via `inertia_share`

## Implementation Plan

### Phase 1: Backend Changes

#### 1.1 Add Pagination Method to Chat Model

- [ ] Add `messages_page` method to Chat model

```ruby
# app/models/chat.rb

def messages_page(before_id: nil, limit: 30)
  scope = messages.includes(:user, :agent).with_attached_attachments.sorted
  scope = scope.where("messages.id < ?", Message.decode_id(before_id)) if before_id.present?
  scope.limit(limit)
end

def total_tokens
  messages.sum("COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)")
end
```

- [ ] Add `total_tokens` to `json_attributes`

```ruby
json_attributes :title_or_default, :model_id, :model_label, :ai_model_name,
                :updated_at_formatted, :updated_at_short, :message_count,
                :total_tokens, :web_access, :manual_responses, ...
```

#### 1.2 Add Simple Scope to Message Model

- [ ] Add `before` scope to Message model

```ruby
# app/models/message.rb

scope :before, ->(id) { where("id < ?", decode_id(id)) }
```

#### 1.3 Update ChatsController#show

- [ ] Modify `show` action to use pagination

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

#### 1.4 Add JSON Endpoint for Older Messages

DHH noted that Inertia partial reloads replace rather than merge arrays. We need a simple JSON endpoint, but keep the controller skinny by delegating to the model.

- [ ] Add `older_messages` action to ChatsController

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

- [ ] Add route for older_messages endpoint

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

#### 1.5 Share Token Thresholds via ApplicationController

- [ ] Add token thresholds to `inertia_share`

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

### Phase 2: Frontend Changes

#### 2.1 Update Props and State Management

The key insight from DHH: Inertia manages the recent messages window from the server. Local state holds only the older messages we've paginated through. Use `$derived` to combine them.

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

  const tokenWarningLevel = $derived(() => {
    if (totalTokens >= thresholds.critical) return 'critical';
    if (totalTokens >= thresholds.red) return 'red';
    if (totalTokens >= thresholds.amber) return 'amber';
    return null;
  });

  // Reset older messages when chat changes
  $effect(() => {
    if (chat?.id) {
      olderMessages = [];
      hasMore = serverHasMore;
      oldestId = serverOldestId;
    }
  });

  // Update pagination state when server props change
  $effect(() => {
    if (!loadingMore) {
      hasMore = serverHasMore;
      oldestId = serverOldestId;
    }
  });
</script>
```

#### 2.2 Implement Scroll Detection and Loading

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

#### 2.3 Update Messages Container

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

#### 2.4 Update visibleMessages Derived

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

#### 2.5 Implement Token Warnings

- [ ] Update header with warning styles and badges

```svelte
<header
  class="border-b border-border px-4 md:px-6 py-3 md:py-4"
  class:bg-red-50={tokenWarningLevel() === 'critical'}
  class:dark:bg-red-950/30={tokenWarningLevel() === 'critical'}
  class:bg-muted/30={tokenWarningLevel() !== 'critical'}
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

        {#if tokenWarningLevel() === 'amber'}
          <Badge variant="outline" class="bg-amber-100 text-amber-800 border-amber-300 dark:bg-amber-900/30 dark:text-amber-400 dark:border-amber-700">
            Long conversation
          </Badge>
        {:else if tokenWarningLevel() === 'red'}
          <Badge variant="outline" class="bg-red-100 text-red-800 border-red-300 dark:bg-red-900/30 dark:text-red-400 dark:border-red-700">
            Very long
          </Badge>
        {:else if tokenWarningLevel() === 'critical'}
          <Badge variant="destructive">
            Extremely long
          </Badge>
        {/if}
      </div>
    </div>
    <!-- rest of header -->
  </div>
</header>

{#if tokenWarningLevel() === 'critical'}
  <div class="bg-red-100 dark:bg-red-900/50 border-b border-red-200 dark:border-red-800 px-4 py-2 text-sm text-red-800 dark:text-red-200">
    <WarningCircle size={16} class="inline mr-2" weight="fill" />
    This conversation is very long ({formatTokenCount(totalTokens)} tokens). Consider
    <button onclick={forkConversation} class="underline font-medium hover:no-underline">
      forking
    </button> or starting a new conversation.
  </div>
{/if}
```

#### 2.6 Remove Complex Sync Logic

DHH's key insight: don't compare message counts. Let ActionCable handle new messages as it already does. The existing real-time sync works fine.

- [ ] Simplify the sync effect - remove message count comparison

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
    // REMOVED: message count comparison logic
    // ActionCable broadcasts handle new messages automatically
  });
</script>
```

### Phase 3: Testing Strategy

#### 3.1 Model Tests

- [ ] Add tests for Chat pagination methods

```ruby
# test/models/chat_test.rb

class ChatTest < ActiveSupport::TestCase
  test "messages_page returns limited messages in sorted order" do
    chat = chats(:one)
    10.times { |i| chat.messages.create!(content: "Message #{i}", role: "user") }

    page = chat.messages_page(limit: 5)

    assert_equal 5, page.count
    assert page.first.created_at <= page.last.created_at
  end

  test "messages_page with before_id returns older messages" do
    chat = chats(:one)
    messages = 10.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user") }
    middle = messages[5]

    page = chat.messages_page(before_id: middle.to_param, limit: 5)

    assert page.all? { |m| m.id < middle.id }
  end

  test "total_tokens sums input and output tokens" do
    chat = chats(:one)
    chat.messages.create!(content: "Hello", role: "user", input_tokens: 10, output_tokens: 0)
    chat.messages.create!(content: "Hi there", role: "assistant", input_tokens: 0, output_tokens: 20)

    assert_equal 30, chat.total_tokens
  end

  test "total_tokens handles nil values" do
    chat = chats(:one)
    chat.messages.create!(content: "Hello", role: "user", input_tokens: nil, output_tokens: nil)

    assert_equal 0, chat.total_tokens
  end
end
```

#### 3.2 Controller Tests

- [ ] Add tests for ChatsController pagination

```ruby
# test/controllers/chats_controller_test.rb

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @account = accounts(:one)
    sign_in(@user)
  end

  test "show loads limited messages" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    50.times { |i| chat.messages.create!(content: "Message #{i}", role: "user") }

    get account_chat_path(@account, chat)

    assert_response :success
    # Inertia props should have limited messages
  end

  test "older_messages returns JSON with pagination info" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    messages = 50.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user") }

    get older_messages_account_chat_path(@account, chat, before_id: messages.last.to_param),
        headers: { 'Accept' => 'application/json' }

    assert_response :success
    json = JSON.parse(response.body)
    assert json.key?('messages')
    assert json.key?('has_more')
    assert json.key?('oldest_id')
  end

  test "older_messages returns empty when no more messages" do
    chat = @account.chats.create!(model_id: "openrouter/auto")
    message = chat.messages.create!(content: "Only message", role: "user")

    get older_messages_account_chat_path(@account, chat, before_id: message.to_param),
        headers: { 'Accept' => 'application/json' }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [], json['messages']
    assert_equal false, json['has_more']
  end
end
```

#### 3.3 Integration Tests (Playwright)

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

## Files to Modify

### Backend
- `/app/models/chat.rb` - Add `messages_page` and `total_tokens` methods
- `/app/models/message.rb` - Add `before` scope
- `/app/controllers/chats_controller.rb` - Update `show`, add `older_messages`
- `/app/controllers/application_controller.rb` - Add `token_thresholds` to `inertia_share`
- `/config/routes.rb` - Add `older_messages` route

### Frontend
- `/app/frontend/pages/chats/show.svelte` - Pagination state, scroll detection, token warnings

### Tests
- `/test/models/chat_test.rb`
- `/test/controllers/chats_controller_test.rb`
- `/test/e2e/chat-pagination.spec.js` (new file)

## Comparison with First Iteration

| Aspect | First Iteration | Revised |
|--------|-----------------|---------|
| Controller methods | 4 private methods | 1 action delegating to model |
| Model methods | 2 scopes in Message | 1 scope + 2 methods in Chat |
| Frontend state variables | 6+ new state vars | 4 focused vars |
| Sync logic | Complex count comparison | Trust existing ActionCable |
| Scroll preservation | Reactive state + effect | Single `requestAnimationFrame` |
| Token thresholds | Hardcoded in JS | Server-provided via `inertia_share` |
| Token calculation | 2 SQL queries | 1 SQL query |

**Estimated code reduction: ~40%**

## Checklist Summary

- [ ] Add `messages_page(before_id:, limit:)` to Chat model
- [ ] Add `total_tokens` to Chat model using single SQL query
- [ ] Add `total_tokens` to Chat json_attributes
- [ ] Add `before` scope to Message model
- [ ] Update `ChatsController#show` with pagination
- [ ] Add `ChatsController#older_messages` JSON endpoint
- [ ] Add route for `older_messages`
- [ ] Add `token_thresholds` to ApplicationController inertia_share
- [ ] Update Svelte: separate `olderMessages` state
- [ ] Update Svelte: `allMessages` derived combining both
- [ ] Update Svelte: scroll detection with `requestAnimationFrame`
- [ ] Update Svelte: token warnings from server thresholds
- [ ] Remove message count comparison from sync logic
- [ ] Add model tests for pagination
- [ ] Add controller tests for both endpoints
- [ ] Add Playwright integration tests
