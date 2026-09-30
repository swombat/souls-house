# AI Conversations Implementation Plan

## Executive Summary

This plan details the implementation of a fully-featured AI chat interface for HelixKit, leveraging the existing Rails backend infrastructure with a new Svelte 5 frontend. The system will provide real-time streaming of AI responses through ActionCable, with a two-pane layout showing conversation list and active chat. The implementation follows Rails conventions and the established architectural patterns of the application.

## Architecture Overview

### Backend Infrastructure (Already Implemented)
- **Models**: `Chat` and `Message` with account scoping and broadcasting
- **Controllers**: `ChatsController` and `MessagesController` with Inertia integration
- **Jobs**: `AiResponseJob` for streaming AI responses, `GenerateTitleJob` for auto-titling
- **Broadcasting**: ActionCable with Broadcastable concern for real-time updates
- **API Integration**: OpenRouterApi with model selection support

### Frontend Architecture (To Be Implemented)
- **Layout**: Two-pane interface with conversation list (left) and chat pane (right)
- **Components**: Modular Svelte 5 components using runes for state management
- **Synchronization**: dynamicSync for real-time message streaming
- **Navigation**: New "Chats" menu item in main navigation
- **State Management**: Lazy chat creation with optimistic UI updates

## Implementation Steps

### Phase 1: Navigation and Routing

- [ ] Update `/app/frontend/lib/components/navigation/Navbar.svelte`
  - Add "Chats" link after "Documentation" in the links array
  - Conditionally show only for authenticated users
  ```javascript
  const links = [
    { href: '/documentation', label: 'Documentation' },
    ...(currentUser ? [{ href: `/accounts/${currentAccount?.id}/chats`, label: 'Chats' }] : []),
    { href: '#', label: 'About' },
  ];
  ```

- [ ] Add route helper to `/app/frontend/routes.js`
  ```javascript
  export const accountChatsPath = (accountId) => `/accounts/${accountId}/chats`;
  export const accountChatPath = (accountId, chatId) => `/accounts/${accountId}/chats/${chatId}`;
  ```

### Phase 2: Chat List Components

- [ ] Create `/app/frontend/pages/Chats/Index.svelte`
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { useSync } from '$lib/use-sync';
    import ChatList from './components/ChatList.svelte';
    import EmptyState from './components/EmptyState.svelte';
    import NewChatButton from './components/NewChatButton.svelte';
    
    let { chats = [] } = $props();
    const account = $page.props.account;
    
    // Subscribe to chat updates
    useSync({
      [`Account:${account.id}`]: 'chats'
    });
  </script>
  
  <div class="container mx-auto p-6">
    <div class="flex justify-between items-center mb-6">
      <h1 class="text-2xl font-bold">AI Conversations</h1>
      <NewChatButton accountId={account.id} />
    </div>
    
    {#if chats.length > 0}
      <ChatList {chats} {account} />
    {:else}
      <EmptyState />
    {/if}
  </div>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/ChatList.svelte`
  ```svelte
  <script>
    import { router } from '@inertiajs/svelte';
    import { formatDistanceToNow } from 'date-fns';
    
    let { chats, account } = $props();
    
    function openChat(chat) {
      router.visit(`/accounts/${account.id}/chats/${chat.id}`);
    }
  </script>
  
  <div class="grid gap-2">
    {#each chats as chat}
      <button
        onclick={() => openChat(chat)}
        class="text-left p-4 rounded-lg border hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
      >
        <h3 class="font-semibold">{chat.title || 'New Conversation'}</h3>
        <p class="text-sm text-muted-foreground">
          {formatDistanceToNow(new Date(chat.updated_at), { addSuffix: true })}
        </p>
      </button>
    {/each}
  </div>
  ```

### Phase 3: Chat Interface Components

- [ ] Create `/app/frontend/pages/Chats/Show.svelte`
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { createDynamicSync } from '$lib/use-sync';
    import ChatSidebar from './components/ChatSidebar.svelte';
    import ChatPane from './components/ChatPane.svelte';
    import MessageInput from './components/MessageInput.svelte';
    
    let { chat, messages = [], chats = [] } = $props();
    const account = $page.props.account;
    
    const updateSync = createDynamicSync();
    
    // Dynamic subscription for current chat and messages
    $effect(() => {
      const subs = {
        [`Account:${account.id}`]: 'chats',
        [`Chat:${chat.id}`]: ['chat', 'messages']
      };
      updateSync(subs);
    });
    
    let isSubmitting = $state(false);
  </script>
  
  <div class="flex h-[calc(100vh-4rem)]">
    <!-- Sidebar with chat list -->
    <ChatSidebar {chats} {account} currentChatId={chat.id} />
    
    <!-- Main chat area -->
    <div class="flex-1 flex flex-col">
      <ChatPane {chat} {messages} />
      <MessageInput 
        chatId={chat.id} 
        accountId={account.id}
        bind:isSubmitting 
      />
    </div>
  </div>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/ChatPane.svelte`
  ```svelte
  <script>
    import { onMount, tick } from 'svelte';
    import MessageBubble from './MessageBubble.svelte';
    
    let { chat, messages = [] } = $props();
    let messagesContainer = $state();
    
    // Auto-scroll to bottom when new messages arrive
    $effect(() => {
      if (messages.length && messagesContainer) {
        tick().then(() => {
          messagesContainer.scrollTop = messagesContainer.scrollHeight;
        });
      }
    });
  </script>
  
  <div class="flex-1 overflow-y-auto p-4" bind:this={messagesContainer}>
    {#if messages.length === 0}
      <div class="text-center text-muted-foreground mt-8">
        <p>Start a conversation by typing a message below</p>
      </div>
    {:else}
      <div class="space-y-4 max-w-3xl mx-auto">
        {#each messages as message}
          <MessageBubble {message} />
        {/each}
      </div>
    {/if}
  </div>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/MessageBubble.svelte`
  ```svelte
  <script>
    import { cn } from '$lib/utils';
    import Avatar from '$lib/components/Avatar.svelte';
    import { page } from '@inertiajs/svelte';
    import MarkdownRenderer from './MarkdownRenderer.svelte';
    import RetryButton from './RetryButton.svelte';
    
    let { message } = $props();
    const currentUser = $page.props.user;
    
    const isUser = message.role === 'user';
    const isStreaming = $derived(message.role === 'assistant' && !message.completed);
    const hasFailed = $derived(message.error);
  </script>
  
  <div class={cn("flex gap-3", isUser ? "justify-end" : "justify-start")}>
    {#if !isUser}
      <div class="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center">
        AI
      </div>
    {/if}
    
    <div class={cn(
      "max-w-[70%] rounded-lg p-3",
      isUser ? "bg-primary text-primary-foreground" : "bg-muted"
    )}>
      {#if hasFailed}
        <div class="text-destructive">
          Failed to get response. 
          <RetryButton messageId={message.id} />
        </div>
      {:else}
        <MarkdownRenderer content={message.content} />
        {#if isStreaming}
          <span class="inline-block w-2 h-4 bg-current animate-pulse ml-1" />
        {/if}
      {/if}
    </div>
    
    {#if isUser}
      <Avatar user={currentUser} size="small" class="!size-8" />
    {/if}
  </div>
  ```

### Phase 4: Message Input and Model Selection

- [ ] Create `/app/frontend/pages/Chats/components/MessageInput.svelte`
  ```svelte
  <script>
    import { router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import { Textarea } from '$lib/components/shadcn/textarea';
    
    let { chatId, accountId, isSubmitting = $bindable() } = $props();
    
    let messageContent = $state('');
    
    async function sendMessage(e) {
      e.preventDefault();
      if (!messageContent.trim() || isSubmitting) return;
      
      isSubmitting = true;
      const content = messageContent;
      messageContent = ''; // Clear input immediately
      
      router.post(
        `/accounts/${accountId}/chats/${chatId}/messages`,
        { message: { content } },
        {
          preserveScroll: true,
          onFinish: () => {
            isSubmitting = false;
          }
        }
      );
    }
    
    function handleKeydown(e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendMessage(e);
      }
    }
  </script>
  
  <form onsubmit={sendMessage} class="border-t p-4">
    <div class="max-w-3xl mx-auto flex gap-2">
      <Textarea
        bind:value={messageContent}
        onkeydown={handleKeydown}
        placeholder="Type your message..."
        disabled={isSubmitting}
        class="flex-1 min-h-[60px] max-h-[200px]"
      />
      <Button 
        type="submit" 
        disabled={!messageContent.trim() || isSubmitting}
      >
        {isSubmitting ? 'Sending...' : 'Send'}
      </Button>
    </div>
  </form>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/NewChatButton.svelte`
  ```svelte
  <script>
    import { router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import * as Dialog from '$lib/components/shadcn/dialog';
    import * as Select from '$lib/components/shadcn/select';
    import { Plus } from 'phosphor-svelte';
    
    let { accountId } = $props();
    
    let open = $state(false);
    let selectedModel = $state('openrouter/auto');
    let messageContent = $state('');
    let isCreating = $state(false);
    
    // Available models from OpenRouterApi
    const models = [
      { value: 'openrouter/auto', label: 'Auto (Recommended)' },
      { value: 'openai/gpt-4o-mini', label: 'GPT-4 Mini' },
      { value: 'anthropic/claude-3.7-sonnet', label: 'Claude 3.7 Sonnet' },
      { value: 'google/gemini-2.5-pro-preview-03-25', label: 'Gemini 2.5 Pro' },
      { value: 'x-ai/grok-3-mini-beta', label: 'Grok 3 Mini' }
    ];
    
    async function createChat() {
      if (!messageContent.trim() || isCreating) return;
      
      isCreating = true;
      
      // Create chat with initial message
      router.post(
        `/accounts/${accountId}/chats`,
        { 
          chat: { model_id: selectedModel },
          initial_message: messageContent
        },
        {
          onSuccess: () => {
            open = false;
            messageContent = '';
            selectedModel = 'openrouter/auto';
          },
          onFinish: () => {
            isCreating = false;
          }
        }
      );
    }
  </script>
  
  <Dialog.Root bind:open>
    <Dialog.Trigger>
      <Button>
        <Plus class="mr-2" />
        New Chat
      </Button>
    </Dialog.Trigger>
    <Dialog.Content>
      <Dialog.Header>
        <Dialog.Title>Start New Conversation</Dialog.Title>
        <Dialog.Description>
          Choose an AI model and type your first message
        </Dialog.Description>
      </Dialog.Header>
      
      <div class="space-y-4">
        <div>
          <label class="text-sm font-medium">Model</label>
          <Select.Root bind:value={selectedModel}>
            <Select.Trigger>
              <Select.Value />
            </Select.Trigger>
            <Select.Content>
              {#each models as model}
                <Select.Item value={model.value}>{model.label}</Select.Item>
              {/each}
            </Select.Content>
          </Select.Root>
        </div>
        
        <div>
          <label class="text-sm font-medium">Your Message</label>
          <Textarea
            bind:value={messageContent}
            placeholder="Ask anything..."
            class="min-h-[100px]"
          />
        </div>
      </div>
      
      <Dialog.Footer>
        <Button variant="outline" onclick={() => open = false}>
          Cancel
        </Button>
        <Button 
          onclick={createChat}
          disabled={!messageContent.trim() || isCreating}
        >
          {isCreating ? 'Creating...' : 'Start Chat'}
        </Button>
      </Dialog.Footer>
    </Dialog.Content>
  </Dialog.Root>
  ```

### Phase 5: Supporting Components

- [ ] Create `/app/frontend/pages/Chats/components/ChatSidebar.svelte`
  ```svelte
  <script>
    import { router } from '@inertiajs/svelte';
    import { cn } from '$lib/utils';
    import { formatDistanceToNow } from 'date-fns';
    import NewChatButton from './NewChatButton.svelte';
    
    let { chats, account, currentChatId } = $props();
    
    function selectChat(chat) {
      router.visit(`/accounts/${account.id}/chats/${chat.id}`);
    }
  </script>
  
  <div class="w-64 border-r bg-muted/10 flex flex-col">
    <div class="p-4 border-b">
      <NewChatButton accountId={account.id} />
    </div>
    
    <div class="flex-1 overflow-y-auto p-2">
      {#each chats as chat}
        <button
          onclick={() => selectChat(chat)}
          class={cn(
            "w-full text-left p-3 rounded-md mb-1 transition-colors",
            chat.id === currentChatId 
              ? "bg-primary/10 text-primary" 
              : "hover:bg-muted"
          )}
        >
          <div class="font-medium truncate">
            {chat.title || 'New Conversation'}
          </div>
          <div class="text-xs text-muted-foreground">
            {formatDistanceToNow(new Date(chat.updated_at), { addSuffix: true })}
          </div>
        </button>
      {/each}
    </div>
  </div>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/MarkdownRenderer.svelte`
  ```svelte
  <script>
    import { marked } from 'marked';
    import hljs from 'highlight.js';
    
    let { content = '' } = $props();
    
    // Configure marked for code highlighting
    marked.setOptions({
      highlight: function(code, lang) {
        if (lang && hljs.getLanguage(lang)) {
          return hljs.highlight(code, { language: lang }).value;
        }
        return hljs.highlightAuto(code).value;
      }
    });
    
    const html = $derived(marked(content));
  </script>
  
  <div class="prose prose-sm dark:prose-invert max-w-none">
    {@html html}
  </div>
  
  <style>
    :global(.prose pre) {
      @apply bg-gray-900 text-gray-100 rounded-md p-3 overflow-x-auto;
    }
    
    :global(.prose code:not(pre code)) {
      @apply bg-gray-100 dark:bg-gray-800 px-1 py-0.5 rounded text-sm;
    }
  </style>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/RetryButton.svelte`
  ```svelte
  <script>
    import { router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import { ArrowClockwise } from 'phosphor-svelte';
    
    let { messageId } = $props();
    let isRetrying = $state(false);
    
    function retry() {
      isRetrying = true;
      router.post(
        `/messages/${messageId}/retry`,
        {},
        {
          preserveScroll: true,
          onFinish: () => {
            isRetrying = false;
          }
        }
      );
    }
  </script>
  
  <Button 
    variant="ghost" 
    size="sm"
    onclick={retry}
    disabled={isRetrying}
  >
    <ArrowClockwise class={cn("mr-1", isRetrying && "animate-spin")} />
    {isRetrying ? 'Retrying...' : 'Retry'}
  </Button>
  ```

- [ ] Create `/app/frontend/pages/Chats/components/EmptyState.svelte`
  ```svelte
  <script>
    import { ChatCircle } from 'phosphor-svelte';
  </script>
  
  <div class="text-center py-12">
    <ChatCircle class="mx-auto h-12 w-12 text-muted-foreground mb-4" />
    <h3 class="text-lg font-semibold mb-2">No conversations yet</h3>
    <p class="text-muted-foreground">
      Start a new chat to begin exploring AI assistance
    </p>
  </div>
  ```

### Phase 6: Controller Enhancements

- [ ] Update `/app/controllers/chats_controller.rb` for lazy creation
  ```ruby
  def create
    @chat = current_account.chats.build(chat_params)
    
    # Handle initial message if provided
    if params[:initial_message].present?
      @chat.save!
      message = @chat.messages.create!(
        content: params[:initial_message],
        role: 'user',
        user: current_user
      )
      AiResponseJob.perform_later(@chat, message)
    else
      @chat.save!
    end
    
    redirect_to [ @chat.account, @chat ]
  end
  
  def index
    @chats = current_account.chats.includes(:messages).order(updated_at: :desc)
    
    # For the show page, also include all chats for sidebar
    if params[:id]
      @chat = current_account.chats.find(params[:id])
      @messages = @chat.messages.includes(:user, files_attachments: :blob)
      render inertia: "Chats/Show", props: {
        chat: @chat,
        messages: @messages,
        chats: @chats
      }
    else
      render inertia: "Chats/Index", props: { chats: @chats }
    end
  end
  ```

- [ ] Add retry endpoint to `/app/controllers/messages_controller.rb`
  ```ruby
  def retry
    @message = Message.find(params[:id])
    @chat = @message.chat
    
    # Verify access
    authorize_chat!
    
    # Clear error state and trigger new response
    @message.update!(error: nil)
    AiResponseJob.perform_later(@chat, @chat.messages.where(role: 'user').last)
    
    head :ok
  end
  
  private
  
  def authorize_chat!
    raise ActiveRecord::RecordNotFound unless current_account.chats.exists?(@chat.id)
  end
  ```

### Phase 7: Dependencies and Configuration

- [ ] Install required packages
  ```bash
  yarn add marked highlight.js date-fns
  yarn add -D @types/marked
  ```

- [ ] Add route for message retry in `/config/routes.rb`
  ```ruby
  resources :messages, only: [] do
    member do
      post :retry
    end
  end
  ```

- [ ] Update Tailwind config for prose styling
  ```javascript
  // tailwind.config.js
  module.exports = {
    // ...
    plugins: [
      require('@tailwindcss/typography'),
      // ... other plugins
    ]
  }
  ```

## Real-time Synchronization Details

### Subscription Channels
1. **Account-level updates**: `Account:${accountId}` - Updates chat list
2. **Chat-level updates**: `Chat:${chatId}` - Updates chat title and metadata
3. **Message streaming**: `Chat:${chatId}` - Streams new messages and content updates

### Message Streaming Flow
1. User sends message → Controller creates user message
2. AiResponseJob starts → Creates empty assistant message
3. AI API streams tokens → Message content updates incrementally
4. Each update broadcasts → Frontend receives via ActionCable
5. Completion marked → Streaming indicator removed

## Error Handling

### Network Failures
- Retry mechanism for failed AI responses
- Offline state detection with reconnection
- Optimistic updates with rollback on failure

### API Errors
- Rate limiting handled with user feedback
- Model availability checks before selection
- Graceful degradation to alternative models

### User Experience
- Loading states during message sending
- Clear error messages with actionable steps
- Persistent retry buttons for failed messages

## Performance Optimizations

### Frontend
- Virtual scrolling for long conversations
- Lazy loading of older messages
- Code splitting for chat components
- Debounced typing indicators

### Backend
- N+1 query prevention with includes
- Efficient broadcasting with filtered updates
- Background job prioritization for active chats
- Caching of model availability

## Testing Strategy

### Unit Tests
- [ ] Model validations and associations
- [ ] Controller authorization and responses
- [ ] Job processing and error handling
- [ ] Broadcasting behavior

### Integration Tests
- [ ] End-to-end chat creation flow
- [ ] Message sending and streaming
- [ ] Real-time synchronization
- [ ] Error recovery scenarios

### Component Tests
- [ ] Svelte component rendering
- [ ] User interactions
- [ ] State management
- [ ] Subscription lifecycle

## Security Considerations

1. **Account Scoping**: All queries scoped through current_account
2. **User Attribution**: Messages linked to current_user
3. **CSRF Protection**: Token validation on all mutations
4. **Content Sanitization**: HTML escaped in markdown rendering
5. **File Upload Validation**: Type and size restrictions (future)

## Future Enhancements

1. **Message Features**
   - Edit/delete messages
   - Copy message content
   - Message reactions
   - Code execution sandboxing

2. **Chat Management**
   - Search across conversations
   - Export chat history
   - Share conversations
   - Folder organization

3. **Advanced Features**
   - File/image uploads
   - Voice input/output
   - Custom system prompts
   - Multi-modal interactions

4. **Performance**
   - Message pagination
   - Incremental search indexing
   - WebSocket connection pooling
   - CDN for static assets

## Dependencies Summary

### Ruby Gems (Already Installed)
- rails (8.0.2)
- ruby-llm
- solid_cable
- solid_queue
- inertia_rails

### NPM Packages (To Install)
- marked (^9.0.0) - Markdown rendering
- highlight.js (^11.0.0) - Code syntax highlighting
- date-fns (^2.30.0) - Date formatting
- @tailwindcss/typography (^0.5.0) - Prose styling

### External Services
- OpenRouter API - AI model routing
- OpenAI API - GPT models
- Anthropic API - Claude models

## Implementation Timeline

**Day 1-2**: Navigation, routing, and basic UI structure
**Day 3-4**: Chat list and creation flow with model selection
**Day 5-6**: Message interface and real-time streaming
**Day 7-8**: Error handling, retry logic, and polish
**Day 9-10**: Testing, bug fixes, and documentation

## Conclusion

This implementation provides a robust, real-time AI chat system that leverages Rails' strengths while delivering a modern, responsive frontend experience. The architecture is designed for maintainability, scalability, and progressive enhancement, following established patterns while introducing powerful new capabilities.