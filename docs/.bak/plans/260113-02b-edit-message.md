# Edit Last Message - Implementation Plan (Revised)

## Summary

Allow users to edit their last message before AI responds. Server-computed editability, fat model, skinny controller.

## Model

Add to `app/models/message.rb`:

```ruby
json_attributes :role, :content, ..., :editable

def editable
  editable_by?(Current.user)
end

def editable_by?(user)
  role == "user" && user_id == user&.id && !has_subsequent_messages?
end

private

def has_subsequent_messages?
  chat.messages.where("created_at > ?", created_at).exists?
end
```

## Routes

Add to `config/routes.rb`:

```ruby
resources :messages, only: [] do
  member do
    post :retry
    patch :update  # Add this
  end
end
```

## Controller

Add to `app/controllers/messages_controller.rb`:

```ruby
before_action :set_message, only: :update

def update
  unless @message.editable_by?(Current.user)
    return head :forbidden
  end

  if @message.update(message_params)
    head :ok
  else
    render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity
  end
end

private

def set_message
  @message = Message.find(params[:id])
  @chat = current_account.chats.find(@message.chat_id)
end
```

## Frontend

### Route Helper

Add to `app/frontend/routes.js`:

```javascript
export function updateMessagePath(id) {
  return `/messages/${id}`;
}
```

### State (in show.svelte)

```javascript
let editingMessageId = $state(null);
let editingContent = $state('');

function startEditingMessage(message) {
  editingMessageId = message.id;
  editingContent = message.content;
}

function cancelEditingMessage() {
  editingMessageId = null;
  editingContent = '';
}

async function saveEditedMessage() {
  const response = await fetch(updateMessagePath(editingMessageId), {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
    },
    body: JSON.stringify({ message: { content: editingContent } }),
  });

  if (response.ok) {
    cancelEditingMessage();
    router.reload({ only: ['messages'], preserveScroll: true });
  }
}
```

### Edit Button (in message rendering)

```svelte
{#if message.role === 'user'}
  <div class="flex justify-end group">
    <div class="max-w-[85%] md:max-w-[70%]">
      <Card.Root>
        <Card.Content class="p-4">
          <!-- existing content -->
        </Card.Content>
      </Card.Root>
      <div class="text-xs text-muted-foreground text-right mt-1 flex items-center justify-end gap-2">
        {#if message.editable}
          <button
            onclick={() => startEditingMessage(message)}
            class="opacity-50 hover:opacity-100 md:opacity-0 md:group-hover:opacity-50 md:group-hover:hover:opacity-100 transition-opacity">
            <PencilSimple size={14} />
          </button>
        {/if}
        <span>{formatTime(message.created_at)}</span>
      </div>
    </div>
  </div>
{/if}
```

### Edit Drawer

```svelte
<Drawer.Root bind:open={editingMessageId !== null} onClose={cancelEditingMessage}>
  <Drawer.Content class="max-h-[50vh]">
    <Drawer.Header>
      <Drawer.Title>Edit Message</Drawer.Title>
    </Drawer.Header>
    <div class="p-4 space-y-4">
      <textarea
        bind:value={editingContent}
        class="w-full min-h-[100px] resize-none border border-input rounded-md px-3 py-2 text-sm bg-background focus:outline-none focus:ring-2 focus:ring-ring"
      ></textarea>
      <div class="flex justify-end gap-2">
        <Button variant="outline" onclick={cancelEditingMessage}>Cancel</Button>
        <Button onclick={saveEditedMessage} disabled={!editingContent.trim()}>Save</Button>
      </div>
    </div>
  </Drawer.Content>
</Drawer.Root>
```

## Tests

Add to `test/controllers/messages_controller_test.rb`:

```ruby
test "updates message content" do
  message = messages(:user_message_without_response)

  patch update_message_path(message), params: { message: { content: "Updated content" } }

  assert_response :ok
  assert_equal "Updated content", message.reload.content
end

test "cannot edit message with subsequent messages" do
  message = messages(:user_message_with_response)

  patch update_message_path(message), params: { message: { content: "Updated" } }

  assert_response :forbidden
end
```

## Implementation Checklist

- [ ] Add `editable_by?` and `has_subsequent_messages?` methods to Message model
- [ ] Add `editable` to `json_attributes` in Message model
- [ ] Add update route for messages
- [ ] Add `set_message` and `update` action to MessagesController
- [ ] Add `updateMessagePath` route helper
- [ ] Add edit state and functions to show.svelte
- [ ] Add edit button with hover/touch visibility to message rendering
- [ ] Add edit drawer component
- [ ] Add test fixtures for messages with/without responses
- [ ] Add controller tests
