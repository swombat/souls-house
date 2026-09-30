# AI Conversations Implementation Plan (Final)

## Executive Summary

This final specification implements AI chat functionality following Rails conventions as closely as possible within the Svelte/Inertia constraints. The implementation uses only 3 simple components that act as dumb display terminals, with all business logic in Rails models. The architecture emphasizes server ownership of state, minimal client-side complexity, and maximum use of Inertia's built-in features.

## Key Design Principles

### Following DHH's Feedback
1. **3 simple components**: Index (list view), Show (chat view), and ChatList (reusable sidebar partial)
2. **Fat models, skinny controllers**: All business logic in models
3. **Server owns state**: Markdown rendering, date formatting, model configuration all server-side
4. **Inertia's useForm**: Leverage built-in form handling instead of manual state
5. **Simple subscriptions**: Direct useSync calls, no complex effects
6. **Dumb components**: Components are display terminals, not state managers

## Architecture Overview

### Backend (Already Implemented)
- `Chat` and `Message` models with broadcasting via Broadcastable
- `ChatsController` and `MessagesController` with RESTful actions
- `AiResponseJob` for streaming AI responses
- `GenerateTitleJob` for auto-titling conversations
- ActionCable for real-time updates

### Frontend (To Be Implemented)
- **3 Svelte Components**:
  1. `Chats/Index.svelte` - Chat list with inline new chat form
  2. `Chats/Show.svelte` - Chat interface with messages and input
  3. `Chats/ChatList.svelte` - Reusable sidebar partial for Show view

## Implementation Steps

### Phase 1: Update Navigation

- [ ] Add to `/app/frontend/lib/components/navigation/Navbar.svelte`
```javascript
// In the links array after Documentation
{
  href: `/accounts/${currentAccount?.id}/chats`,
  label: 'Chats',
  show: !!currentUser
}
```

### Phase 2: Enhance Models with Business Logic

- [ ] Update `/app/models/chat.rb`
```ruby
class Chat < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  
  acts_as_chat
  
  belongs_to :account
  has_many :messages, dependent: :destroy
  
  broadcasts_to :account
  
  validates :model_id, presence: true
  
  after_create_commit -> { GenerateTitleJob.perform_later(self) }, unless: :title?
  
  # Available AI models
  MODELS = [
    ['openrouter/auto', 'Auto (Recommended)'],
    ['openai/gpt-4o-mini', 'GPT-4 Mini'],
    ['anthropic/claude-3.7-sonnet', 'Claude 3.7 Sonnet'],
    ['google/gemini-2.5-pro-preview-03-25', 'Gemini 2.5 Pro']
  ].freeze
  
  scope :latest, -> { order(updated_at: :desc) }
  
  # Create chat with optional initial message
  def self.create_with_message!(attributes, message_content: nil, user: nil)
    transaction do
      chat = create!(attributes)
      if message_content.present?
        message = chat.messages.create!(
          content: message_content,
          role: 'user',
          user: user
        )
        AiResponseJob.perform_later(chat, message)
      end
      chat
    end
  end
  
  # Props for Inertia rendering
  def to_props_hash
    {
      id: to_param,
      title: title.presence || "New Conversation", 
      model_id: model_id,
      model_name: MODELS.find { |m| m[0] == model_id }&.last,
      updated_at_formatted: updated_at.strftime("%b %d at %l:%M %p"),
      message_count: messages.count
    }
  end
  
  # Minimal props for sidebar
  def to_sidebar_props
    {
      id: to_param,
      title: title.presence || "New Conversation",
      updated_at_formatted: updated_at.strftime("%b %d")
    }
  end
end
```

- [ ] Update `/app/models/message.rb`
```ruby
class Message < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  
  acts_as_message
  
  belongs_to :chat, touch: true
  belongs_to :user, optional: true
  
  has_many_attached :files
  
  broadcasts_to :chat
  
  validates :role, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true
  
  def to_props_hash
    {
      id: to_param,
      role: role,
      content_html: render_markdown,
      user_name: user&.full_name,
      user_avatar_url: user&.avatar_url,
      completed: completed?,
      error: error,
      created_at_formatted: created_at.strftime("%l:%M %p")
    }
  end
  
  def completed?
    role == 'user' || (role == 'assistant' && completed)
  end
  
  private
  
  def render_markdown
    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(
        filter_html: true,
        safe_links_only: true,
        hard_wrap: true
      ),
      autolink: true,
      fenced_code_blocks: true,
      tables: true,
      strikethrough: true
    )
    renderer.render(content || "").html_safe
  end
end
```

### Phase 3: Update Controllers

- [ ] Update `/app/controllers/chats_controller.rb`
```ruby
class ChatsController < ApplicationController
  before_action :set_chat, only: [:show, :destroy]
  
  def index
    @chats = current_account.chats.includes(:messages).latest
    
    render inertia: "Chats/Index", props: {
      chats: @chats.map(&:to_props_hash),
      models: Chat::MODELS
    }
  end
  
  def show
    @chats = current_account.chats.latest
    @messages = @chat.messages.includes(:user)
    
    render inertia: "Chats/Show", props: {
      chat: @chat.to_props_hash,
      chats: @chats.map(&:to_sidebar_props),
      messages: @messages.map(&:to_props_hash)
    }
  end
  
  def create
    @chat = current_account.chats.create_with_message!(
      chat_params,
      message_content: params[:message],
      user: current_user
    )
    redirect_to account_chat_path(current_account, @chat)
  end
  
  def destroy
    @chat.destroy!
    redirect_to account_chats_path(current_account)
  end
  
  private
  
  def set_chat
    @chat = current_account.chats.find(params[:id])
  end
  
  def chat_params
    params.fetch(:chat, {})
      .permit(:model_id)
      .with_defaults(model_id: 'openrouter/auto')
  end
end
```

- [ ] Update `/app/controllers/messages_controller.rb`
```ruby
class MessagesController < ApplicationController
  before_action :set_chat
  
  def create
    @message = @chat.messages.create!(
      message_params.merge(user: current_user, role: 'user')
    )
    
    AiResponseJob.perform_later(@chat, @message)
    
    redirect_to account_chat_path(@chat.account, @chat)
  end
  
  def retry
    @message = @chat.messages.find(params[:id])
    
    # Clear error and retry
    @message.update!(error: nil, completed: false)
    last_user_message = @chat.messages.where(role: 'user').last
    AiResponseJob.perform_later(@chat, last_user_message) if last_user_message
    
    head :ok
  end
  
  private
  
  def set_chat
    @chat = current_account.chats.find(params[:chat_id])
  end
  
  def message_params
    params.require(:message).permit(:content)
  end
end
```

### Phase 4: Create Simple Svelte Components

- [ ] Create `/app/frontend/pages/Chats/Index.svelte`
```svelte
<script>
  import { page } from '@inertiajs/svelte';
  import { useForm } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { ChatCircle, Plus } from 'phosphor-svelte';
  
  let { chats = [], models = [] } = $props();
  const account = $page.props.account;
  
  // Subscribe to chat updates
  useSync({
    [`Account:${account.id}`]: 'chats'
  });
  
  // Form for new chat
  const form = useForm({
    model_id: 'openrouter/auto',
    message: ''
  });
  
  let showNewChat = $state(false);
  
  function createChat() {
    $form.post(`/accounts/${account.id}/chats`, {
      onSuccess: () => {
        showNewChat = false;
        $form.reset();
      }
    });
  }
</script>

<div class="container mx-auto p-6 max-w-4xl">
  <div class="flex justify-between items-center mb-6">
    <h1 class="text-3xl font-bold">AI Conversations</h1>
    <Button onclick={() => showNewChat = !showNewChat}>
      <Plus class="mr-2" />
      New Chat
    </Button>
  </div>
  
  {#if showNewChat}
    <Card class="mb-6">
      <CardHeader>
        <CardTitle>Start New Conversation</CardTitle>
      </CardHeader>
      <CardContent>
        <form onsubmit|preventDefault={createChat}>
          <div class="space-y-4">
            <div>
              <label for="model" class="block text-sm font-medium mb-2">
                AI Model
              </label>
              <select
                id="model"
                bind:value={$form.model_id}
                class="w-full p-2 border rounded-md"
              >
                {#each models as [value, label]}
                  <option {value}>{label}</option>
                {/each}
              </select>
            </div>
            
            <div>
              <label for="message" class="block text-sm font-medium mb-2">
                Your Message
              </label>
              <textarea
                id="message"
                bind:value={$form.message}
                placeholder="Ask anything..."
                required
                class="w-full p-3 border rounded-md min-h-[100px]"
              />
            </div>
            
            <div class="flex gap-2">
              <Button type="submit" disabled={$form.processing}>
                {$form.processing ? 'Creating...' : 'Start Chat'}
              </Button>
              <Button 
                type="button"
                variant="outline"
                onclick={() => showNewChat = false}
              >
                Cancel
              </Button>
            </div>
          </div>
        </form>
      </CardContent>
    </Card>
  {/if}
  
  {#if chats.length > 0}
    <div class="grid gap-3">
      {#each chats as chat}
        <Card class="hover:shadow-md transition-shadow">
          <CardContent class="p-4">
            <a href={`/accounts/${account.id}/chats/${chat.id}`} class="block">
              <h3 class="font-semibold text-lg">{chat.title}</h3>
              <div class="flex justify-between items-center mt-2 text-sm text-muted-foreground">
                <span>{chat.message_count} messages</span>
                <span>{chat.updated_at_formatted}</span>
              </div>
            </a>
          </CardContent>
        </Card>
      {/each}
    </div>
  {:else if !showNewChat}
    <Card>
      <CardContent class="text-center py-12">
        <ChatCircle class="mx-auto h-12 w-12 text-muted-foreground mb-4" />
        <h3 class="text-lg font-semibold mb-2">No conversations yet</h3>
        <p class="text-muted-foreground">
          Start a new chat to begin exploring AI assistance
        </p>
      </CardContent>
    </Card>
  {/if}
</div>
```

- [ ] Create `/app/frontend/pages/Chats/Show.svelte`
```svelte
<script>
  import { page } from '@inertiajs/svelte';
  import { useForm } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button';
  import Avatar from '$lib/components/Avatar.svelte';
  import ChatList from './ChatList.svelte';
  import { Send, ArrowClockwise } from 'phosphor-svelte';
  import { onMount, tick } from 'svelte';
  
  let { chat, chats = [], messages = [] } = $props();
  const account = $page.props.account;
  const currentUser = $page.props.user;
  
  // Subscribe to updates
  useSync({
    [`Account:${account.id}`]: 'chats',
    [`Chat:${chat.id}`]: ['chat', 'messages']
  });
  
  // Message form
  const form = useForm({
    content: ''
  });
  
  let messagesContainer = $state();
  
  // Auto-scroll on new messages
  $effect(() => {
    if (messages.length && messagesContainer) {
      tick().then(() => {
        messagesContainer.scrollTop = messagesContainer.scrollHeight;
      });
    }
  });
  
  function sendMessage() {
    $form.post(`/accounts/${account.id}/chats/${chat.id}/messages`, {
      onSuccess: () => $form.reset(),
      preserveScroll: true
    });
  }
  
  function retryMessage(messageId) {
    // Simple POST without form
    fetch(`/messages/${messageId}/retry`, {
      method: 'POST',
      headers: {
        'X-CSRF-Token': document.querySelector('[name="csrf-token"]').content
      }
    });
  }
</script>

<div class="flex h-[calc(100vh-4rem)]">
  <!-- Sidebar -->
  <ChatList {chats} {account} currentChatId={chat.id} />
  
  <!-- Main chat -->
  <main class="flex-1 flex flex-col">
    <!-- Messages -->
    <div class="flex-1 overflow-y-auto p-4" bind:this={messagesContainer}>
      {#if messages.length === 0}
        <div class="text-center text-muted-foreground mt-8">
          <p>Start a conversation by typing a message below</p>
        </div>
      {:else}
        <div class="space-y-4 max-w-3xl mx-auto">
          {#each messages as message}
            <div class="flex gap-3 {message.role === 'user' ? 'justify-end' : ''}">
              {#if message.role === 'assistant'}
                <div class="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center">
                  AI
                </div>
              {/if}
              
              <div class="max-w-[70%] rounded-lg p-3 {message.role === 'user' ? 'bg-primary text-primary-foreground' : 'bg-muted'}">
                {#if message.error}
                  <div class="text-destructive">
                    Failed to get response.
                    <Button
                      variant="ghost"
                      size="sm"
                      onclick={() => retryMessage(message.id)}
                    >
                      <ArrowClockwise class="mr-1" />
                      Retry
                    </Button>
                  </div>
                {:else}
                  {@html message.content_html}
                  {#if !message.completed}
                    <span class="inline-block w-2 h-4 bg-current animate-pulse ml-1" />
                  {/if}
                {/if}
                <div class="text-xs opacity-60 mt-1">
                  {message.created_at_formatted}
                </div>
              </div>
              
              {#if message.role === 'user'}
                <Avatar user={currentUser} size="small" class="!size-8" />
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
    
    <!-- Input -->
    <form onsubmit|preventDefault={sendMessage} class="border-t p-4">
      <div class="max-w-3xl mx-auto flex gap-2">
        <textarea
          bind:value={$form.content}
          onkeydown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              sendMessage();
            }
          }}
          placeholder="Type your message..."
          disabled={$form.processing}
          required
          class="flex-1 p-3 border rounded-md resize-none min-h-[60px] max-h-[200px]"
        />
        <Button type="submit" disabled={$form.processing} class="self-end">
          {#if $form.processing}
            Sending...
          {:else}
            <Send class="size-4" />
          {/if}
        </Button>
      </div>
    </form>
  </main>
</div>

<style>
  /* Server-rendered HTML styles */
  :global(.max-w-\[70\%] pre) {
    @apply bg-gray-900 text-gray-100 rounded p-3 overflow-x-auto my-2;
  }
  
  :global(.max-w-\[70\%] code:not(pre code)) {
    @apply bg-gray-100 dark:bg-gray-800 px-1 py-0.5 rounded text-sm;
  }
  
  :global(.max-w-\[70\%] ul, .max-w-\[70\%] ol) {
    @apply ml-4 my-2;
  }
</style>
```

- [ ] Create `/app/frontend/pages/Chats/ChatList.svelte`
```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Plus } from 'phosphor-svelte';
  
  let { chats, account, currentChatId } = $props();
  
  function selectChat(chatId) {
    router.visit(`/accounts/${account.id}/chats/${chatId}`);
  }
  
  function newChat() {
    router.visit(`/accounts/${account.id}/chats`);
  }
</script>

<aside class="w-64 border-r bg-muted/10 flex flex-col">
  <div class="p-4 border-b">
    <Button class="w-full" onclick={newChat}>
      <Plus class="mr-2" />
      New Chat
    </Button>
  </div>
  
  <div class="flex-1 overflow-y-auto p-2">
    {#each chats as chat}
      <button
        onclick={() => selectChat(chat.id)}
        class="w-full text-left p-3 rounded-md mb-1 transition-colors
               {chat.id === currentChatId ? 'bg-primary/10 text-primary' : 'hover:bg-muted'}"
      >
        <div class="font-medium truncate">{chat.title}</div>
        <div class="text-xs text-muted-foreground">
          {chat.updated_at_formatted}
        </div>
      </button>
    {/each}
  </div>
</aside>
```

### Phase 5: Add Routes

- [ ] Update `/config/routes.rb` to add retry endpoint
```ruby
# After the existing chat/message routes
resources :messages, only: [] do
  member do
    post :retry
  end
end
```

## Key Simplifications Achieved

### What We Eliminated
1. **Complex state management** - useForm handles all form state
2. **Manual subscription effects** - Direct useSync calls
3. **Client-side markdown** - Server renders everything
4. **Complex retry logic** - Simple fetch for retry
5. **Unnecessary abstractions** - Direct, obvious code

### What We Kept Simple
1. **3 focused components** - Each does one thing well
2. **Server owns logic** - Models contain all business rules
3. **Inertia patterns** - useForm for all form handling
4. **Direct subscriptions** - No dynamic effects needed
5. **Rails conventions** - RESTful routes, fat models

## Testing Strategy

### Model Tests
- [ ] Test `Chat.create_with_message!` transaction
- [ ] Test message markdown rendering
- [ ] Test prop serialization methods

### Controller Tests
- [ ] Test authorization scoping
- [ ] Test chat creation with initial message
- [ ] Test message retry endpoint

### System Tests
- [ ] Test full chat flow with Playwright
- [ ] Test real-time updates
- [ ] Test error handling

## Performance & Security

### Performance
- Server-side markdown rendering (once per message)
- Efficient queries with includes
- Simple DOM structure for fast rendering
- Minimal client-side JavaScript

### Security
- All authorization through Rails associations
- CSRF protection via Inertia
- HTML sanitization in Redcarpet
- No client-side secrets

## The Rails Way Achieved

This implementation follows Rails philosophy:
1. **Fat models** - Business logic in `Chat.create_with_message!`
2. **Skinny controllers** - Controllers just orchestrate
3. **Server owns state** - Markdown, dates, configuration all server-side
4. **Convention over configuration** - Standard RESTful patterns
5. **Simple and boring** - Code any Rails developer understands instantly

## Conclusion

This final specification achieves maximum simplicity while working within Svelte/Inertia constraints. The components are dumb display terminals, the server owns all state and logic, and the code follows Rails conventions throughout. Any Rails developer could understand and maintain this code with minimal Svelte knowledge.