# RESTful Resource Refactoring Plan (v2)

## Goal

Refactor the application's routing and controllers to follow the 37signals RESTful resource pattern from `docs/restful-resource-design.md`. Custom member/collection actions become focused, single-purpose controllers. This is primarily moving code around — no functionality changes.

## Current State

Several controllers have become "junk drawers" with custom actions:
- **ChatsController** — 10 custom member actions
- **AgentsController** — 7 custom actions (memories CRUD + telegrams + triggers)
- **MessagesController** — 2 custom actions (retry, fix hallucinations)
- **ApiKeysController** — 3 custom actions (approval flow)
- **UsersController** — 2 custom actions (password editing) + confused avatar destroy
- **API::V1::ConversationsController** — 1 custom action (create_message)

## Sync Impact

Route changes do NOT affect ActionCable, model callbacks, or real-time synchronization. The sync system broadcasts model changes independently of routing, so this refactoring is safe.

## Frontend Impact

js-routes auto-regenerates when Rails routes change. All Svelte files using route helpers will need updated helper names. There are also hardcoded URL instances across frontend files that should be migrated to route helpers during this refactor.

---

## Phase 1: ChatsController (Biggest Win)

The chats controller has 10 custom actions. Extract each into a focused controller.

### New Routes

```ruby
resources :accounts, only: [:show, :edit, :update] do
  resources :chats do
    scope module: :chats do
      resource :archive, only: [:create, :destroy]       # archive / unarchive
      resource :discard, only: [:create, :destroy]        # discard / restore
      resource :fork, only: :create                       # fork chat
      resource :moderation, only: :create                 # moderate all messages
      resource :agent_assignment, only: :create           # assign single agent (converts chat mode)
      resource :participant, only: :create                # add agent to group chat
      resource :agent_trigger, only: :create              # trigger agent(s)
    end
    resources :messages, only: [:index, :create]          # add index for older_messages
  end
end
```

### New Controllers

All live in `app/controllers/chats/` and include a shared `ChatScoped` concern.

| Controller | Actions | Replaces |
|---|---|---|
| `Chats::ArchivesController` | `create` (archive), `destroy` (unarchive) | `chats#archive`, `chats#unarchive` |
| `Chats::DiscardsController` | `create` (discard), `destroy` (restore) | `chats#discard`, `chats#restore` |
| `Chats::ForksController` | `create` | `chats#fork` |
| `Chats::ModerationsController` | `create` | `chats#moderate_all` |
| `Chats::AgentAssignmentsController` | `create` | `chats#assign_agent` |
| `Chats::ParticipantsController` | `create` | `chats#add_agent` |
| `Chats::AgentTriggersController` | `create` | `chats#trigger_agent` + `chats#trigger_all_agents` (no `agent_id` means "trigger all") |

### Shared Concern: `ChatScoped`

```ruby
# app/controllers/concerns/chat_scoped.rb
module ChatScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_chat
  end

  private

  def set_chat
    @chat = current_account.chats.with_discarded.find(params[:chat_id])
  end
end
```

This delegates to `current_account` from the existing `AccountScoping` concern rather than re-implementing account lookup. The `with_discarded` scope preserves the existing behavior that allows admins to find discarded chats for restore operations.

### Agent Trigger Convention

`Chats::AgentTriggersController#create` handles both single-agent and all-agent triggers through a single `resource :agent_trigger, only: :create`. When `agent_id` is present in params, it triggers that specific agent. When absent, it triggers all agents. This is documented in the controller:

```ruby
# app/controllers/chats/agent_triggers_controller.rb
class Chats::AgentTriggersController < ApplicationController
  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/agent_trigger
  #
  # Triggers AI response from agent(s) in this chat.
  # Pass agent_id to trigger a specific agent, omit to trigger all.
  def create
    if params[:agent_id].present?
      agent = @chat.agents.find(params[:agent_id])
      @chat.trigger_agent_response!(agent)
    else
      @chat.trigger_all_agents_response!
    end

    respond_to do |format|
      format.html { redirect_to account_chat_path(current_account, @chat) }
      format.json { head :ok }
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(current_account, @chat), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end
end
```

### Participants Controller

```ruby
# app/controllers/chats/participants_controller.rb
class Chats::ParticipantsController < ApplicationController
  include ChatScoped

  def create
    unless @chat.group_chat?
      redirect_back_or_to account_chat_path(current_account, @chat),
        alert: "Can only add agents to group chats"
      return
    end

    agent = current_account.agents.find(params[:agent_id])

    if @chat.agents.include?(agent)
      redirect_back_or_to account_chat_path(current_account, @chat),
        alert: "#{agent.name} is already in this conversation"
      return
    end

    @chat.transaction do
      @chat.agents << agent
      @chat.messages.create!(
        role: "user",
        content: "[System Notice] #{agent.name} has joined the conversation."
      )
    end

    audit("add_agent_to_chat", @chat, agent_id: agent.id)
    redirect_to account_chat_path(current_account, @chat)
  end
end
```

### Messages Index (older_messages)

Move the `older_messages` action into `MessagesController#index` under chats. The pagination logic stays identical — it returns messages before a given ID.

Current: `GET /accounts/:account_id/chats/:chat_id/older_messages?before_id=X`
New: `GET /accounts/:account_id/chats/:chat_id/messages?before_id=X`

### Frontend Updates (Phase 1)

Route helper renames:
- `archiveAccountChatPath` → `accountChatArchivePath` (POST)
- `unarchiveAccountChatPath` → `accountChatArchivePath` (DELETE)
- `discardAccountChatPath` → `accountChatDiscardPath` (POST)
- `restoreAccountChatPath` → `accountChatDiscardPath` (DELETE)
- `forkAccountChatPath` → `accountChatForkPath`
- `moderateAllAccountChatPath` → `accountChatModerationPath`
- `assignAgentAccountChatPath` → `accountChatAgentAssignmentPath`
- `addAgentAccountChatPath` → `accountChatParticipantPath`
- `triggerAgentAccountChatPath` → `accountChatAgentTriggerPath` (with agent_id param)
- `triggerAllAgentsAccountChatPath` → `accountChatAgentTriggerPath` (no agent_id param)
- `olderMessagesAccountChatPath` → `accountChatMessagesPath` (with before_id param)

Files to update:
- `app/frontend/pages/chats/show.svelte`
- `app/frontend/lib/components/chat/AgentTriggerBar.svelte`

---

## Phase 2: AgentsController

### New Routes

```ruby
resources :accounts do
  resource :agent_initiation, only: :create, module: :accounts  # trigger all agent initiations
  resources :agents, except: [:show, :new] do
    scope module: :agents do
      resource :refinement, only: :create                       # trigger memory refinement
      resource :telegram_test, only: :create                    # send test telegram
      resource :telegram_webhook, only: :create                 # register webhook
      resources :memories, only: :create do
        scope module: :memories do
          resource :discard, only: [:create, :destroy]          # create = soft-delete, destroy = restore
          resource :protection, only: [:create, :destroy]       # create = protect, destroy = unprotect
        end
      end
    end
  end
end
```

### New Controllers

All live in `app/controllers/agents/` or `app/controllers/agents/memories/`.

| Controller | Actions | Replaces |
|---|---|---|
| `Accounts::AgentInitiationsController` | `create` | `agents#trigger_initiation` (collection) |
| `Agents::RefinementsController` | `create` | `agents#trigger_refinement` |
| `Agents::TelegramTestsController` | `create` | `agents#send_test_telegram` |
| `Agents::TelegramWebhooksController` | `create` | `agents#register_telegram_webhook` |
| `Agents::MemoriesController` | `create` | `agents#create_memory` |
| `Agents::Memories::DiscardsController` | `create` (discard), `destroy` (restore) | `agents#destroy_memory`, `agents#undiscard_memory` |
| `Agents::Memories::ProtectionsController` | `create` (protect), `destroy` (unprotect) | `agents#toggle_constitutional` |

### Memory Discard Semantics

Memories are never hard-deleted. The `destroy` action is dropped from `resources :memories`. Instead, soft-delete and restore are handled through the discard sub-resource:

- `POST /agents/:agent_id/memories/:memory_id/discard` — soft-deletes the memory
- `DELETE /agents/:agent_id/memories/:memory_id/discard` — restores the memory

```ruby
# app/controllers/agents/memories/discards_controller.rb
class Agents::Memories::DiscardsController < ApplicationController
  include AgentScoped

  before_action :set_memory

  def create
    if @memory.discard
      redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory discarded"
    else
      redirect_to edit_account_agent_path(current_account, @agent), alert: "Cannot discard a protected memory"
    end
  end

  def destroy
    @memory.undiscard!
    redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory restored"
  end

  private

  def set_memory
    @memory = @agent.memories.find(params[:memory_id])
  end
end
```

### Memory Protection Semantics

Protection replaces the "constitutional" toggle. Instead of a PATCH toggle, this uses create/destroy on a state resource:

- `POST /agents/:agent_id/memories/:memory_id/protection` — protects the memory
- `DELETE /agents/:agent_id/memories/:memory_id/protection` — unprotects the memory

```ruby
# app/controllers/agents/memories/protections_controller.rb
class Agents::Memories::ProtectionsController < ApplicationController
  include AgentScoped

  before_action :set_memory

  def create
    @memory.update!(constitutional: true)
    audit("memory_protected", @memory)
    redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory protected"
  end

  def destroy
    @memory.update!(constitutional: false)
    audit("memory_unprotected", @memory)
    redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory unprotected"
  end

  private

  def set_memory
    @memory = @agent.memories.find(params[:memory_id])
  end
end
```

### Shared Concern: `AgentScoped`

```ruby
# app/controllers/concerns/agent_scoped.rb
module AgentScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_agent
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:agent_id])
  end
end
```

This delegates to `current_account` from the existing `AccountScoping` concern, consistent with how the rest of the application works.

### Frontend Updates (Phase 2)

Route helper renames:
- `createMemoryAccountAgentPath` → `accountAgentMemoriesPath` (POST)
- `destroyMemoryAccountAgentPath` → `accountAgentMemoryDiscardPath` (POST)
- `undiscardMemoryAccountAgentPath` → `accountAgentMemoryDiscardPath` (DELETE)
- `toggleConstitutionalAccountAgentPath` → `accountAgentMemoryProtectionPath` (POST to protect, DELETE to unprotect)
- `sendTestTelegramAccountAgentPath` → `accountAgentTelegramTestPath`
- `registerTelegramWebhookAccountAgentPath` → `accountAgentTelegramWebhookPath`
- `triggerRefinementAccountAgentPath` → `accountAgentRefinementPath`
- `triggerInitiationAccountAgentsPath` → `accountAgentInitiationPath`

Files to update:
- `app/frontend/pages/agents/edit.svelte`
- `app/frontend/pages/agents/index.svelte`

---

## Phase 3: MessagesController

### New Routes

```ruby
resources :messages, only: [:update, :destroy] do
  scope module: :messages do
    resource :retry, only: :create                    # trigger AI re-generation
    resource :hallucination_fix, only: :create        # fix hallucinated tool calls
  end
end
```

### New Controllers

| Controller | Actions | Replaces |
|---|---|---|
| `Messages::RetriesController` | `create` | `messages#retry` |
| `Messages::HallucinationFixesController` | `create` | `messages#fix_hallucinated_tool_calls` |

### Frontend Updates (Phase 3)

- `retryMessagePath` → `messageRetryPath`
- `fixHallucinatedToolCallsMessagePath` → `messageHallucinationFixPath`

Files to update:
- `app/frontend/pages/chats/show.svelte`

---

## Phase 4: ApiKeysController (Approval Flow)

### New Routes

```ruby
resources :api_keys, only: [:index, :create, :destroy]
resources :api_key_approvals, only: [:show, :create, :destroy],
  param: :token, path: "api_keys/approvals"
```

This gives:
- `GET /api_keys/approvals/:token` — show approval form
- `POST /api_keys/approvals/:token` — approve
- `DELETE /api_keys/approvals/:token` — deny

The routing declaration is honest about the relationship: approvals are keyed by token (not by api_key ID), so they are a standalone resource that shares the URL prefix for readability.

### New Controller

| Controller | Actions | Replaces |
|---|---|---|
| `ApiKeyApprovalsController` | `show`, `create`, `destroy` | `api_keys#approve`, `api_keys#confirm_approve`, `api_keys#deny` |

```ruby
# app/controllers/api_key_approvals_controller.rb
class ApiKeyApprovalsController < ApplicationController
  before_action :set_key_request

  def show
    if @key_request.expired?
      redirect_to api_keys_path, alert: "This request has expired"
      return
    end

    if @key_request.approved? || @key_request.denied?
      redirect_to api_keys_path, alert: "This request has already been processed"
      return
    end

    render inertia: "api_keys/approve", props: {
      client_name: @key_request.client_name,
      token: params[:token],
      expires_at: @key_request.expires_at.iso8601
    }
  end

  def create
    if @key_request.expired? || !@key_request.pending?
      redirect_to api_keys_path, alert: "This request is no longer valid"
      return
    end

    key_name = params[:key_name].presence || "#{@key_request.client_name} Key"
    @key_request.approve!(user: Current.user, key_name: key_name)

    render inertia: "api_keys/approved", props: {
      client_name: @key_request.client_name
    }
  end

  def destroy
    @key_request.deny! if @key_request.pending?
    redirect_to api_keys_path, notice: "Request denied"
  end

  private

  def set_key_request
    @key_request = ApiKeyRequest.find_by!(request_token: params[:token])
  rescue ActiveRecord::RecordNotFound
    redirect_to api_keys_path, alert: "Invalid request"
  end
end
```

### Frontend Updates (Phase 4)

- `approveApiKeyPath` → `apiKeyApprovalPath` (GET for form, POST for approve)
- `denyApiKeyPath` → `apiKeyApprovalPath` (DELETE)

Files to update:
- `app/frontend/pages/api_keys/approve.svelte` (if it references route helpers)

---

## Phase 5: UsersController (Password + Avatar)

### New Routes

```ruby
resource :user, only: %i[edit update] do
  scope module: :users do
    resource :password, only: [:edit, :update]
    resource :avatar, only: :destroy
  end
end
```

This gives:
- `GET /user/password/edit` → `Users::PasswordsController#edit`
- `PATCH /user/password` → `Users::PasswordsController#update`
- `DELETE /user/avatar` → `Users::AvatarsController#destroy`

The confused `user_avatar` route that pointed to `UsersController#destroy` is replaced with a properly namespaced `Users::AvatarsController#destroy`.

### New Controllers

| Controller | Actions | Replaces |
|---|---|---|
| `Users::PasswordsController` | `edit`, `update` | `users#edit_password`, `users#update_password` |
| `Users::AvatarsController` | `destroy` | `users#destroy` (via `user_avatar` route) |

```ruby
# app/controllers/users/avatars_controller.rb
class Users::AvatarsController < ApplicationController
  def destroy
    Current.user.profile&.avatar&.purge_later
    audit(:remove_avatar, Current.user)

    inertia_request? ?
      redirect_with_inertia_flash(:success, "Avatar removed successfully", edit_user_path) :
      render(json: { success: true }, status: :ok)
  end

  private

  def inertia_request?
    request.headers["X-Inertia"].present?
  end
end
```

### Frontend Updates (Phase 5)

- `editPasswordUserPath` → `editUserPasswordPath`
- `updatePasswordUserPath` → `userPasswordPath` (PATCH)
- `destroyUserAvatarPath` → `userAvatarPath` (DELETE)

Files to update:
- `app/frontend/lib/components/forms/ChangePasswordForm.svelte`
- `app/frontend/lib/components/navigation/navbar.svelte` (if it links to password edit)
- `app/frontend/pages/user/edit_password.svelte` (if route helpers used)

---

## Phase 6: API::V1 (Nested Messages)

### New Routes

```ruby
namespace :api do
  namespace :v1 do
    resources :conversations, only: [:index, :show] do
      resources :messages, only: :create
    end
  end
end
```

This gives: `POST /api/v1/conversations/:conversation_id/messages`

Replaces: `POST /api/v1/conversations/:id/create_message`

### New Controller

| Controller | Actions | Replaces |
|---|---|---|
| `Api::V1::MessagesController` | `create` | `api/v1/conversations#create_message` |

```ruby
# app/controllers/api/v1/messages_controller.rb
module Api
  module V1
    class MessagesController < BaseController
      def create
        chat = current_api_account.chats.find(params[:conversation_id])

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        message = chat.messages.create!(
          content: params[:content],
          role: "user",
          user: current_api_user
        )

        AiResponseJob.perform_later(chat) unless chat.manual_responses?

        render json: {
          message: { id: message.to_param, content: message.content, created_at: message.created_at.iso8601 },
          ai_response_triggered: !chat.manual_responses?
        }, status: :created
      end
    end
  end
end
```

---

## Implementation Approach

### For Each Phase:

- [ ] Create the new controller — extract the action body from the existing controller
- [ ] Add the shared concern (if needed) — `ChatScoped`, `AgentScoped`
- [ ] Update routes.rb — replace custom actions with resource declarations
- [ ] Run `rails routes` — verify new route names
- [ ] Update frontend — replace old route helpers with new ones, convert hardcoded URLs
- [ ] Update tests — adjust controller test paths and route assertions
- [ ] Run `rails test` — verify nothing breaks
- [ ] Run `bin/rubocop` — verify linting passes
- [ ] Remove old code — delete custom actions from original controller

### Phase-by-Phase Checklist

#### Phase 1: ChatsController
- [ ] Create `app/controllers/concerns/chat_scoped.rb`
- [ ] Create `app/controllers/chats/archives_controller.rb`
- [ ] Create `app/controllers/chats/discards_controller.rb`
- [ ] Create `app/controllers/chats/forks_controller.rb`
- [ ] Create `app/controllers/chats/moderations_controller.rb`
- [ ] Create `app/controllers/chats/agent_assignments_controller.rb`
- [ ] Create `app/controllers/chats/participants_controller.rb`
- [ ] Create `app/controllers/chats/agent_triggers_controller.rb`
- [ ] Add `index` action to existing `MessagesController` (nested under chats)
- [ ] Update `config/routes.rb` for chats
- [ ] Update `app/frontend/pages/chats/show.svelte`
- [ ] Update `app/frontend/lib/components/chat/AgentTriggerBar.svelte`
- [ ] Move `before_action :require_admin` into `Chats::DiscardsController`
- [ ] Move `before_action :require_site_admin` into `Chats::ModerationsController`
- [ ] Create `test/controllers/chats/archives_controller_test.rb`
- [ ] Create `test/controllers/chats/discards_controller_test.rb`
- [ ] Create `test/controllers/chats/forks_controller_test.rb`
- [ ] Create `test/controllers/chats/moderations_controller_test.rb`
- [ ] Create `test/controllers/chats/agent_assignments_controller_test.rb`
- [ ] Create `test/controllers/chats/participants_controller_test.rb`
- [ ] Create `test/controllers/chats/agent_triggers_controller_test.rb`
- [ ] Remove extracted actions from `ChatsController`
- [ ] Update existing `test/controllers/chats_controller_test.rb`
- [ ] Run `rails test` and `bin/rubocop`

#### Phase 2: AgentsController
- [ ] Create `app/controllers/concerns/agent_scoped.rb`
- [ ] Create `app/controllers/accounts/agent_initiations_controller.rb`
- [ ] Create `app/controllers/agents/refinements_controller.rb`
- [ ] Create `app/controllers/agents/telegram_tests_controller.rb`
- [ ] Create `app/controllers/agents/telegram_webhooks_controller.rb`
- [ ] Create `app/controllers/agents/memories_controller.rb`
- [ ] Create `app/controllers/agents/memories/discards_controller.rb`
- [ ] Create `app/controllers/agents/memories/protections_controller.rb`
- [ ] Update `config/routes.rb` for agents
- [ ] Update `app/frontend/pages/agents/edit.svelte`
- [ ] Update `app/frontend/pages/agents/index.svelte`
- [ ] Create tests for all new controllers
- [ ] Remove extracted actions from `AgentsController`
- [ ] Update existing `test/controllers/agents_controller_test.rb`
- [ ] Run `rails test` and `bin/rubocop`

#### Phase 3: MessagesController
- [ ] Create `app/controllers/messages/retries_controller.rb`
- [ ] Create `app/controllers/messages/hallucination_fixes_controller.rb`
- [ ] Update `config/routes.rb` for messages
- [ ] Update `app/frontend/pages/chats/show.svelte`
- [ ] Create tests for new controllers
- [ ] Remove extracted actions from `MessagesController`
- [ ] Update existing `test/controllers/messages_controller_test.rb`
- [ ] Run `rails test` and `bin/rubocop`

#### Phase 4: ApiKeysController
- [ ] Create `app/controllers/api_key_approvals_controller.rb`
- [ ] Update `config/routes.rb` for API key approvals
- [ ] Update frontend if approval pages reference route helpers
- [ ] Create `test/controllers/api_key_approvals_controller_test.rb`
- [ ] Remove extracted actions from `ApiKeysController`
- [ ] Run `rails test` and `bin/rubocop`

#### Phase 5: UsersController
- [ ] Create `app/controllers/users/passwords_controller.rb`
- [ ] Create `app/controllers/users/avatars_controller.rb`
- [ ] Update `config/routes.rb` for user password and avatar
- [ ] Update `app/frontend/lib/components/forms/ChangePasswordForm.svelte`
- [ ] Update `app/frontend/pages/user/edit_password.svelte` (if needed)
- [ ] Create tests for new controllers
- [ ] Remove extracted actions from `UsersController`
- [ ] Remove `user_avatar` route
- [ ] Update existing `test/controllers/users_controller_test.rb`
- [ ] Run `rails test` and `bin/rubocop`

#### Phase 6: API::V1
- [ ] Create `app/controllers/api/v1/messages_controller.rb`
- [ ] Update `config/routes.rb` for API messages
- [ ] Create `test/controllers/api/v1/messages_controller_test.rb`
- [ ] Remove `create_message` from `Api::V1::ConversationsController`
- [ ] Update existing `test/controllers/api/v1/conversations_controller_test.rb`
- [ ] Run `rails test` and `bin/rubocop`

### What Does NOT Change:

- Model code (no business logic changes)
- ActionCable channels or sync behavior
- Authentication/authorization patterns
- Database schema
- The actual behavior of any action

### Naming Convention for New Controllers:

Following Rails conventions and the 37signals pattern:
- Namespace under parent: `Chats::ArchivesController`
- File location: `app/controllers/chats/archives_controller.rb`
- Singular resource controllers still use plural controller names (Rails convention)

---

## Complete Routes After Refactoring

For reference, here is what the full `config/routes.rb` looks like after all phases:

```ruby
Rails.application.routes.draw do
  # Favicon routes
  get "favicon.:format", to: "favicon#show", as: :favicon, defaults: { format: "ico" }
  get "favicon", to: "favicon#show", defaults: { format: "ico" }

  # Documentation
  get "documentation" => "documentation#index", as: :documentation

  get "login" => "sessions#new", as: :login
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  get "signup" => "registrations#new", as: :signup
  post "signup" => "registrations#create"
  get "check-email" => "registrations#check_email", as: :check_email
  get "email-confirmation" => "registrations#confirm_email", as: :email_confirmation
  get "set-password" => "registrations#set_password", as: :set_password
  patch "set-password" => "registrations#update_password"

  resources :passwords, param: :token, only: %i[new create edit update]

  resource :user, only: %i[edit update] do
    scope module: :users do
      resource :password, only: [:edit, :update]
      resource :avatar, only: :destroy
    end
  end

  # API Key Management (browser-based)
  resources :api_keys, only: [:index, :create, :destroy]
  resources :api_key_approvals, only: [:show, :create, :destroy],
    param: :token, path: "api_keys/approvals"

  # Telegram webhook (called by Telegram, no auth)
  post "telegram/webhook/:token", to: "telegram_webhooks#receive", as: :telegram_webhook

  resources :accounts, only: [:show, :edit, :update] do
    resources :members, controller: "account_members", only: [:destroy]
    resources :invitations, only: [:create] do
      member do
        post :resend
      end
    end

    resource :agent_initiation, only: :create, module: :accounts

    resources :chats do
      scope module: :chats do
        resource :archive, only: [:create, :destroy]
        resource :discard, only: [:create, :destroy]
        resource :fork, only: :create
        resource :moderation, only: :create
        resource :agent_assignment, only: :create
        resource :participant, only: :create
        resource :agent_trigger, only: :create
      end
      resources :messages, only: [:index, :create]
    end

    resources :agents, except: [:show, :new] do
      scope module: :agents do
        resource :refinement, only: :create
        resource :telegram_test, only: :create
        resource :telegram_webhook, only: :create
        resources :memories, only: :create do
          scope module: :memories do
            resource :discard, only: [:create, :destroy]
            resource :protection, only: [:create, :destroy]
          end
        end
      end
    end

    resources :whiteboards, only: [:index, :update]
  end

  resources :messages, only: [:update, :destroy] do
    scope module: :messages do
      resource :retry, only: :create
      resource :hallucination_fix, only: :create
    end
  end

  namespace :admin do
    resources :accounts, only: [:index]
    resources :audit_logs, only: [:index]
    resource :settings, only: [:show, :update]
  end

  # JSON API for external clients (Claude Code, etc.)
  namespace :api do
    namespace :v1 do
      resources :key_requests, only: [:create, :show]
      resources :conversations, only: [:index, :show] do
        resources :messages, only: :create
      end
      resources :whiteboards, only: [:index, :show, :create, :update]
    end
  end

  # Oura Ring integration (OAuth + settings) — kept as-is
  resource :oura_integration, only: %i[show create update destroy], controller: "oura_integration" do
    get :callback
    post :sync
  end

  # GitHub integration (OAuth + repo selection + settings) — kept as-is
  resource :github_integration, only: %i[show create update destroy], controller: "github_integration" do
    get :callback
    get :select_repo
    post :save_repo
    post :sync
  end

  get "up" => "rails/health#show", as: :rails_health_check

  get "privacy" => "pages#privacy", as: :privacy
  get "terms" => "pages#terms", as: :terms
  get "create_flash" => "pages#create_flash"
  root "pages#home"
end
```

---

## Testing Strategy

Each new controller gets its own test file following the existing integration test pattern:

```ruby
# test/controllers/chats/archives_controller_test.rb
class Chats::ArchivesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "create archives the chat" do
    post account_chat_archive_path(@account, @chat)
    assert @chat.reload.archived?
    assert_redirected_to account_chats_path(@account)
  end

  test "destroy unarchives the chat" do
    @chat.archive!
    delete account_chat_archive_path(@account, @chat)
    assert_not @chat.reload.archived?
  end
end
```

Key testing principles:
- One test file per new controller
- Tests verify both the happy path and authorization
- Existing test assertions are ported (not rewritten) to validate identical behavior
- Integration tests using `ActionDispatch::IntegrationTest` (matching existing pattern)

---

## Out of Scope

The following are intentionally left as-is:

- **Integration controllers (OAuth)** — GitHub and Oura integration controllers use custom actions (`callback`, `sync`, `select_repo`, `save_repo`) that are conventional in the OAuth world. Refactoring them to resource controllers buys little clarity and may confuse developers familiar with OAuth patterns. The ROI is too low.
- **RegistrationsController** — Multi-step signup flow is conventional and doesn't benefit from this pattern
- **Admin namespace** — Already clean, no custom actions
- **Pages/Sessions controllers** — Standard Rails auth patterns
- **Favicon/health routes** — Utility routes, not domain resources
- **Invitations resend** — The `member { post :resend }` on invitations is a minor case that could become `Invitations::DeliveriesController` but the win is marginal for a single action
