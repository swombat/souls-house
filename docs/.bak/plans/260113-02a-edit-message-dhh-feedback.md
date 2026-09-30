# DHH-Style Code Review: Edit Last Message Specification

**Reviewer:** Channeling David Heinemeier Hansson
**Date:** January 13, 2026
**Spec Reviewed:** 260113-02a-edit-message.md

---

## Overall Assessment

This specification is **not yet Rails-worthy**. While the feature itself is simple and valuable, the implementation demonstrates several anti-patterns: over-engineered authorization logic, a convoluted routing decision process documented in the spec itself, and frontend code that duplicates server-side concerns. The spec also commits a cardinal sin by spending 500 lines documenting what should be a 50-line feature addition.

The good news: the bones are there. With surgical removal of unnecessary complexity, this could be exemplary Rails code.

---

## Critical Issues

### 1. The Controller Authorization is Over-Engineered

The proposed controller code:

```ruby
@message = current_account.chats.joins(:messages)
                          .where(messages: { id: params[:id] })
                          .first&.messages&.find(params[:id])
```

This is a mess. You are doing a complex join query, then calling `.first`, then traversing the association *again* to call `.find`. This is the kind of "clever" code that makes future developers weep.

**The fix:** Follow the pattern already established in `set_chat_for_retry`:

```ruby
def set_message
  @message = Message.find(params[:id])
  @chat = current_account.chats.find(@message.chat_id)
end
```

Clean. Simple. Two queries that do exactly what they say. If the user does not have access to the chat, `find` raises `RecordNotFound`. No joins needed.

### 2. Authorization Logic Belongs in the Model, Not the Controller

The spec puts `can_edit?` and `message_has_response?` in the controller. This violates "fat models, skinny controllers." The Message model should know whether it is editable:

```ruby
# In Message model
def editable_by?(user)
  role == "user" && user_id == user.id && !has_subsequent_messages?
end

def has_subsequent_messages?
  chat.messages.where("created_at > ?", created_at).exists?
end
```

The controller then becomes trivial:

```ruby
def update
  return head :forbidden unless @message.editable_by?(Current.user)

  if @message.update(message_params)
    # respond
  end
end
```

### 3. The Routing Discussion Should Not Exist

The spec includes three different routing approaches, with commentary like "Actually, let's keep it RESTful and simple." This indecision has no place in a spec. The answer is obvious: use standard RESTful routing.

```ruby
resources :messages, only: [:update] do
  member do
    post :retry
  end
end
```

Done. No discussion needed. Convention over configuration.

### 4. The Frontend Duplicates Authorization Logic

The spec includes this derived state:

```javascript
const canEditLastMessage = $derived(() => {
  if (!allMessages || allMessages.length === 0) return false;
  const lastMessage = allMessages[allMessages.length - 1];
  if (!lastMessage || lastMessage.role !== 'user') return false;
  if ($page.props.user?.id !== lastMessage.user_id) return false;
  if (waitingForResponse) return false;
  return true;
});
```

This duplicates the server-side authorization logic. What happens when the rules change? You update two places. DRY violation.

**The fix:** Compute `editable` on the server and pass it as a message attribute. The Message model already has `json_attributes` for serialization:

```ruby
# In Message model
json_attributes :role, :content, ..., :editable

def editable
  editable_by?(Current.user) rescue false
end
```

Then the frontend simply checks `message.editable`. One source of truth.

---

## Improvements Needed

### 1. Simplify the Controller Update Action

**Before (spec):**
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
```

**After (Rails-worthy):**
```ruby
before_action :set_message, only: [:update]

def update
  return head :forbidden unless @message.editable_by?(Current.user)

  if @message.update(message_params)
    respond_to do |format|
      format.html { redirect_to account_chat_path(@chat.account, @chat) }
      format.json { render json: @message }
    end
  else
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: @message.errors.full_messages.to_sentence }
      format.json { render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity }
    end
  end
end

private

def set_message
  @message = Message.find(params[:id])
  @chat = current_account.chats.find(@message.chat_id)
end
```

Note: `status: :ok` is unnecessary - it is the default. Do not write code that does nothing.

### 2. Move Business Logic to Message Model

Add to `app/models/message.rb`:

```ruby
def editable_by?(user)
  return false unless role == "user"
  return false unless user_id == user&.id
  return false if has_subsequent_messages?
  true
end

private

def has_subsequent_messages?
  chat.messages.where("created_at > ?", created_at).exists?
end
```

### 3. Simplify Frontend State

Remove the complex derived calculation. Pass editability from the server. The frontend edit button becomes:

```svelte
{#if message.editable}
  <button onclick={() => startEditingMessage(message)}>
    <PencilSimple size={14} />
  </button>
{/if}
```

No complex conditional logic. No duplication of business rules.

### 4. Remove Optimistic Update

The spec includes this:

```javascript
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
```

Optimistic update followed immediately by a reload? This is premature optimization that accomplishes nothing. Just reload after success:

```javascript
if (response.ok) {
  cancelEditingMessage();
  router.reload({ only: ['messages'], preserveScroll: true });
}
```

### 5. Trim the Testing Section

The spec proposes four controller tests and two system tests for a single PATCH endpoint. This is excessive.

**Keep:**
- Test successful edit
- Test cannot edit with subsequent messages (the core business rule)

**Remove:**
- Separate tests for "other user's message" and "assistant message" - these are the same authorization check
- System tests for "desktop hover" - testing CSS :hover states in system tests is fragile and unnecessary

Two focused tests beat six scattered ones.

---

## What Works Well

1. **The feature scope is correct.** Editing only the last message with no response is the right constraint. Simple, useful, no edge-case nightmares.

2. **The drawer UI pattern is consistent** with the existing whiteboard implementation. Reusing established patterns is good Rails thinking.

3. **The security considerations section** correctly identifies the key authorization checks. The spec author understands what matters.

4. **Using existing icons and components.** No unnecessary new dependencies. `PencilSimple` is already imported.

5. **The edge cases table** is thoughtful and shows understanding of real-world failure modes.

---

## Refactored Implementation Summary

### Routes (1 line change)

```ruby
resources :messages, only: [:update] do
  member do
    post :retry
  end
end
```

### Message Model (add ~8 lines)

```ruby
json_attributes :role, :content, ..., :editable

def editable_by?(user)
  role == "user" && user_id == user&.id && !has_subsequent_messages?
end

def editable
  editable_by?(Current.user) rescue false
end

private

def has_subsequent_messages?
  chat.messages.where("created_at > ?", created_at).exists?
end
```

### Controller (add ~20 lines)

```ruby
before_action :set_message, only: [:update]

def update
  return head :forbidden unless @message.editable_by?(Current.user)

  if @message.update(message_params)
    respond_to do |format|
      format.html { redirect_to account_chat_path(@chat.account, @chat) }
      format.json { render json: @message }
    end
  else
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: @message.errors.full_messages.to_sentence }
      format.json { render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity }
    end
  end
end

private

def set_message
  @message = Message.find(params[:id])
  @chat = current_account.chats.find(@message.chat_id)
end
```

### Frontend (simplified)

Remove the `canEditLastMessage` derived state. Use `message.editable` from server. Keep the drawer and edit functions, but simplify `saveEditedMessage` by removing the pointless optimistic update.

### Tests (2 focused tests)

```ruby
test "can edit own last message with no response" do
  message = @chat.messages.create!(content: "Original", role: "user", user: @user)

  patch message_path(message), params: { message: { content: "Edited" } }, as: :json

  assert_response :ok
  assert_equal "Edited", message.reload.content
end

test "cannot edit message when response exists" do
  message = @chat.messages.create!(content: "User message", role: "user", user: @user)
  @chat.messages.create!(content: "AI response", role: "assistant")

  patch message_path(message), params: { message: { content: "Too late" } }, as: :json

  assert_response :forbidden
end
```

---

## Final Verdict

The spec describes a 150-line feature but proposes ~185 lines of implementation plus excessive tests. The refactored version should be closer to 80 lines total (model + controller + simplified frontend changes).

**Recommendation:** Rewrite the spec with the simplifications above. Remove the routing discussion. Move authorization to the model. Trust the server to compute editability. Ship it.

The feature is good. The implementation needs discipline.
