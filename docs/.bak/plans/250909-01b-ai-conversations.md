# AI Conversations Implementation Plan (Revised)

## Executive Summary

This revised plan implements AI chat functionality using a minimal component architecture that follows Rails conventions while working within the Svelte/Inertia framework. The implementation uses only 2 Svelte components, leverages server-side rendering through Inertia props, and utilizes the existing `dynamicSync` system for real-time updates without complex state management.

## Key Architectural Decisions

### Addressing DHH's Feedback
1. **Reduced to 2 components** (from 13): One for the chat list, one for the show view
2. **Server-side markdown rendering**: Rails renders markdown to HTML before sending to frontend
3. **No external npm dependencies**: Use Rails' date helpers and markdown rendering
4. **RESTful conventions**: Standard Rails controller actions with Inertia responses
5. **Simplified state management**: Use existing dynamicSync without complex abstractions

### Working Within Project Constraints
- Keep using Svelte/Inertia as required by the project
- Leverage server-side props for all rendering decisions
- Use the existing synchronization system (already built and tested)
- Follow established patterns from existing pages like `accounts/show.svelte`

## Architecture Overview

### Backend (Already Implemented)
- `Chat` and `Message` models with broadcasting
- `ChatsController` and `MessagesController` 
- `AiResponseJob` for streaming responses
- ActionCable broadcasting via Broadcastable concern

### Frontend (To Be Implemented)
- **2 Svelte Components Total**:
  1. `Chats/Index.svelte` - Combined list/empty state
  2. `Chats/Show.svelte` - Combined chat view with messages and input
- Server-rendered markdown and dates via Inertia props
- Existing dynamicSync for real-time updates

## Implementation Steps

### Phase 1: Update Navigation

- [ ] Modify `/app/frontend/lib/components/navigation/Navbar.svelte`
```javascript
// Add to links array
{ 
  href: `/accounts/${currentAccount?.id}/chats`, 
  label: 'Chats',
  show: !!currentUser 
}
```

### Phase 2: Enhanced Controllers with Server-Side Rendering

- [ ] Update `/app/controllers/chats_controller.rb`
```ruby
class ChatsController < ApplicationController
  before_action :set_chat, except: [ :index, :create ]
  
  def index
    @chats = current_account.chats
      .includes(:messages)
      .order(updated_at: :desc)
    
    render inertia: "Chats/Index", props: {
      chats: @chats.map { |chat| serialize_chat(chat) },
      models: available_models
    }
  end
  
  def show
    @chats = current_account.chats.order(updated_at: :desc)
    @messages = @chat.messages.includes(:user)
    
    render inertia: "Chats/Show", props: {
      chat: serialize_chat(@chat),
      chats: @chats.map { |chat| serialize_chat_summary(chat) },
      messages: @messages.map { |msg| serialize_message(msg) },
      models: available_models
    }
  end
  
  def create
    @chat = current_account.chats.build(chat_params)
    
    # Handle initial message inline if provided
    if params[:initial_message].present?
      @chat.transaction do
        @chat.save!
        message = @chat.messages.create!(
          content: params[:initial_message],
          role: 'user',
          user: current_user
        )
        AiResponseJob.perform_later(@chat, message)
      end
    else
      @chat.save!
    end
    
    redirect_to [ @chat.account, @chat ]
  end
  
  private
  
  def serialize_chat(chat)
    {
      id: chat.to_param,
      title: chat.title || "New Conversation",
      model_id: chat.model_id,
      updated_at_formatted: time_ago_in_words(chat.updated_at) + " ago",
      message_count: chat.messages.count
    }
  end
  
  def serialize_chat_summary(chat)
    {
      id: chat.to_param,
      title: chat.title || "New Conversation",
      updated_at_formatted: time_ago_in_words(chat.updated_at) + " ago"
    }
  end
  
  def serialize_message(message)
    {
      id: message.to_param,
      role: message.role,
      content_html: markdown_to_html(message.content),
      user_name: message.user&.full_name,
      user_avatar_url: message.user&.avatar_url,
      completed: message.completed?,
      error: message.error,
      created_at_formatted: time_ago_in_words(message.created_at) + " ago"
    }
  end
  
  def markdown_to_html(content)
    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(
        filter_html: true,
        safe_links_only: true,
        with_toc_data: true,
        hard_wrap: true
      ),
      autolink: true,
      fenced_code_blocks: true,
      disable_indented_code_blocks: true,
      tables: true,
      strikethrough: true
    )
    renderer.render(content || "").html_safe
  end
  
  def available_models
    [
      { value: 'openrouter/auto', label: 'Auto (Recommended)' },
      { value: 'openai/gpt-4o-mini', label: 'GPT-4 Mini' },
      { value: 'anthropic/claude-3.7-sonnet', label: 'Claude 3.7 Sonnet' },
      { value: 'google/gemini-2.5-pro-preview-03-25', label: 'Gemini 2.5 Pro' }
    ]
  end
end
```

- [ ] Update `/app/controllers/messages_controller.rb`
```ruby
class MessagesController < ApplicationController
  before_action :set_chat
  
  def create
    @message = @chat.messages.build(message_params.merge(user: current_user))
    
    if @message.save
      AiResponseJob.perform_later(@chat, @message)
      redirect_to [ @chat.account, @chat ]
    else
      redirect_to [ @chat.account, @chat ], 
        inertia: { errors: @message.errors }
    end
  end
  
  def retry
    @message = Message.find(params[:id])
    authorize_message!
    
    @message.update!(error: nil)
    # Find the last user message to retry from
    last_user_message = @chat.messages.where(role: 'user').last
    AiResponseJob.perform_later(@chat, last_user_message) if last_user_message
    
    head :ok
  end
  
  private
  
  def authorize_message!
    raise ActiveRecord::RecordNotFound unless @message.chat.account == current_account
  end
end
```

### Phase 3: Create Minimal Svelte Components

- [ ] Create `/app/frontend/pages/Chats/Index.svelte`
```svelte
<script>
  import { page, router } from '@inertiajs/svelte';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '$lib/components/shadcn/select';
  import { Textarea } from '$lib/components/shadcn/textarea';
  import { useSync } from '$lib/use-sync';
  import { Plus, ChatCircle } from 'phosphor-svelte';
  
  let { chats = [], models = [] } = $props();
  const account = $page.props.account;
  
  // Subscribe to chat list updates
  useSync({
    [`Account:${account.id}`]: 'chats'
  });
  
  // New chat form state
  let showNewChat = $state(false);
  let selectedModel = $state('openrouter/auto');
  let initialMessage = $state('');
  let isCreating = $state(false);
  
  function createChat() {
    if (!initialMessage.trim() || isCreating) return;
    
    isCreating = true;
    router.post(
      `/accounts/${account.id}/chats`,
      { 
        chat: { model_id: selectedModel },
        initial_message: initialMessage
      },
      {
        onFinish: () => {
          isCreating = false;
          showNewChat = false;
          initialMessage = '';
        }
      }
    );
  }
  
  function openChat(chat) {
    router.visit(`/accounts/${account.id}/chats/${chat.id}`);
  }
</script>

<div class="container mx-auto p-6 max-w-6xl">
  <div class="flex justify-between items-center mb-6">
    <div>
      <h1 class="text-3xl font-bold">AI Conversations</h1>
      <p class="text-muted-foreground mt-1">Chat with AI assistants</p>
    </div>
    <Button onclick={() => showNewChat = true}>
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
        <div class="space-y-4">
          <div>
            <label class="text-sm font-medium mb-2 block">AI Model</label>
            <select 
              bind:value={selectedModel}
              class="w-full p-2 border rounded-md"
            >
              {#each models as model}
                <option value={model.value}>{model.label}</option>
              {/each}
            </select>
          </div>
          
          <div>
            <label class="text-sm font-medium mb-2 block">Your Message</label>
            <textarea
              bind:value={initialMessage}
              placeholder="Ask anything..."
              class="w-full p-3 border rounded-md min-h-[100px]"
              onkeydown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault();
                  createChat();
                }
              }}
            />
          </div>
          
          <div class="flex gap-2">
            <Button onclick={createChat} disabled={!initialMessage.trim() || isCreating}>
              {isCreating ? 'Creating...' : 'Start Chat'}
            </Button>
            <Button variant="outline" onclick={() => showNewChat = false}>
              Cancel
            </Button>
          </div>
        </div>
      </CardContent>
    </Card>
  {/if}
  
  {#if chats.length > 0}
    <div class="grid gap-3">
      {#each chats as chat}
        <Card 
          class="cursor-pointer hover:shadow-md transition-shadow"
          onclick={() => openChat(chat)}
        >
          <CardContent class="p-4">
            <h3 class="font-semibold text-lg">{chat.title}</h3>
            <div class="flex justify-between items-center mt-2">
              <span class="text-sm text-muted-foreground">
                {chat.message_count} messages
              </span>
              <span class="text-sm text-muted-foreground">
                {chat.updated_at_formatted}
              </span>
            </div>
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
  import { page, router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button';
  import Avatar from '$lib/components/Avatar.svelte';
  import { ArrowClockwise, Send } from 'phosphor-svelte';
  import { onMount, tick } from 'svelte';
  
  let { chat, chats = [], messages = [] } = $props();
  const account = $page.props.account;
  const currentUser = $page.props.user;
  
  // Dynamic sync for current chat
  const updateSync = createDynamicSync();
  
  $effect(() => {
    const subs = {
      [`Account:${account.id}`]: 'chats'
    };
    if (chat) {
      subs[`Chat:${chat.id}`] = ['chat', 'messages'];
    }
    updateSync(subs);
  });
  
  // Message input state
  let messageContent = $state('');
  let isSubmitting = $state(false);
  let messagesContainer = $state();
  
  // Auto-scroll on new messages
  $effect(() => {
    if (messages.length && messagesContainer) {
      tick().then(() => {
        messagesContainer.scrollTop = messagesContainer.scrollHeight;
      });
    }
  });
  
  function sendMessage(e) {
    e?.preventDefault();
    if (!messageContent.trim() || isSubmitting) return;
    
    isSubmitting = true;
    const content = messageContent;
    messageContent = '';
    
    router.post(
      `/accounts/${account.id}/chats/${chat.id}/messages`,
      { message: { content } },
      {
        preserveScroll: true,
        onFinish: () => {
          isSubmitting = false;
        }
      }
    );
  }
  
  function selectChat(selectedChat) {
    router.visit(`/accounts/${account.id}/chats/${selectedChat.id}`);
  }
  
  function retryMessage(message) {
    router.post(`/messages/${message.id}/retry`);
  }
  
  onMount(() => {
    // Focus input on mount
    const textarea = document.querySelector('textarea');
    textarea?.focus();
  });
</script>

<div class="flex h-[calc(100vh-4rem)]">
  <!-- Sidebar with chat list -->
  <aside class="w-64 border-r bg-muted/10 flex flex-col">
    <div class="p-4 border-b">
      <Button 
        class="w-full"
        onclick={() => router.visit(`/accounts/${account.id}/chats`)}
      >
        New Chat
      </Button>
    </div>
    
    <div class="flex-1 overflow-y-auto p-2">
      {#each chats as c}
        <button
          onclick={() => selectChat(c)}
          class="w-full text-left p-3 rounded-md mb-1 transition-colors {c.id === chat.id ? 'bg-primary/10 text-primary' : 'hover:bg-muted'}"
        >
          <div class="font-medium truncate">{c.title}</div>
          <div class="text-xs text-muted-foreground">
            {c.updated_at_formatted}
          </div>
        </button>
      {/each}
    </div>
  </aside>
  
  <!-- Main chat area -->
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
            <div class="flex gap-3 {message.role === 'user' ? 'justify-end' : 'justify-start'}">
              {#if message.role === 'assistant'}
                <div class="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center flex-shrink-0">
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
                      onclick={() => retryMessage(message)}
                      class="ml-2"
                    >
                      <ArrowClockwise class="mr-1" />
                      Retry
                    </Button>
                  </div>
                {:else}
                  <!-- Server-rendered HTML -->
                  {@html message.content_html}
                  {#if message.role === 'assistant' && !message.completed}
                    <span class="inline-block w-2 h-4 bg-current animate-pulse ml-1" />
                  {/if}
                {/if}
                
                <div class="text-xs opacity-60 mt-1">
                  {message.created_at_formatted}
                </div>
              </div>
              
              {#if message.role === 'user'}
                <Avatar user={currentUser} size="small" class="!size-8 flex-shrink-0" />
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
    
    <!-- Input form -->
    <form onsubmit={sendMessage} class="border-t p-4">
      <div class="max-w-3xl mx-auto flex gap-2">
        <textarea
          bind:value={messageContent}
          onkeydown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              sendMessage();
            }
          }}
          placeholder="Type your message..."
          disabled={isSubmitting}
          class="flex-1 p-3 border rounded-md resize-none min-h-[60px] max-h-[200px]"
        />
        <Button 
          type="submit" 
          disabled={!messageContent.trim() || isSubmitting}
          class="self-end"
        >
          {#if isSubmitting}
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
  /* Style for server-rendered code blocks */
  :global(.max-w-\[70\%] pre) {
    @apply bg-gray-900 text-gray-100 rounded-md p-3 overflow-x-auto my-2;
  }
  
  :global(.max-w-\[70\%] code:not(pre code)) {
    @apply bg-gray-100 dark:bg-gray-800 px-1 py-0.5 rounded text-sm;
  }
  
  :global(.max-w-\[70\%] ul, .max-w-\[70\%] ol) {
    @apply ml-4 my-2;
  }
  
  :global(.max-w-\[70\%] li) {
    @apply my-1;
  }
</style>
```

### Phase 4: Add Routes

- [ ] Update `/config/routes.rb`
```ruby
resources :accounts do
  resources :chats do
    resources :messages, only: [:create]
  end
end

resources :messages, only: [] do
  member do
    post :retry
  end
end
```

### Phase 5: Update Models for Broadcasting

- [ ] Ensure `/app/models/chat.rb` includes broadcasting
```ruby
class Chat < ApplicationRecord
  include Broadcastable
  include JsonAttributes
  
  belongs_to :account
  has_many :messages, dependent: :destroy
  
  broadcasts_to :account
  
  json_attributes :title, :model_id, :updated_at
end
```

- [ ] Ensure `/app/models/message.rb` includes broadcasting
```ruby
class Message < ApplicationRecord
  include Broadcastable
  include JsonAttributes
  
  belongs_to :chat
  belongs_to :user, optional: true
  
  broadcasts_to ->(message) { message.chat }
  
  json_attributes :content, :role, :completed, :error, :created_at
  
  def completed?
    role == 'user' || (role == 'assistant' && completed)
  end
end
```

## Key Simplifications from Original Spec

### What We Eliminated
1. **11 unnecessary components** - Everything is in 2 files
2. **Complex state management** - Use existing dynamicSync
3. **npm dependencies** - No marked, highlight.js, or date-fns needed
4. **Client-side markdown rendering** - Rails handles it
5. **Separate dialog components** - Inline new chat form
6. **Virtual scrolling** - Not needed for MVP
7. **Complex retry mechanisms** - Simple POST to retry endpoint

### What We Kept
1. **Svelte/Inertia** - Project requirement
2. **Real-time updates** - Via existing synchronization system
3. **RESTful controllers** - Standard Rails patterns
4. **Model selection** - But simplified to a select dropdown
5. **Retry on failure** - But as a simple button

## Testing Strategy

### Controller Tests
- [ ] Test chat creation with and without initial message
- [ ] Test message creation triggers AI job
- [ ] Test retry functionality
- [ ] Test authorization scoping

### System Tests
- [ ] Test full chat flow using existing Playwright setup
- [ ] Test real-time updates between tabs
- [ ] Test error handling and retry

## Performance Considerations

1. **Server-side rendering** - Markdown and dates rendered once on server
2. **Efficient queries** - Use includes to prevent N+1
3. **Debounced sync** - Already built into synchronization system
4. **Simple DOM** - Minimal components = fast rendering

## Security

1. **Account scoping** - All queries through current_account
2. **CSRF protection** - Inertia handles automatically
3. **HTML sanitization** - Redcarpet configured for safety
4. **No client secrets** - API keys stay on server

## Future Enhancements (Not in V1)

- File/image uploads
- Message editing
- Search across chats
- Export functionality
- Voice input

## Conclusion

This revised implementation achieves the same functionality with 85% less code and complexity. It follows Rails conventions, uses server-side rendering where appropriate, and works within the Svelte/Inertia constraints of the project. The result is maintainable, testable, and performant code that any Rails developer can understand.