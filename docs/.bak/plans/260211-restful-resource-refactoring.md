# RESTful Resource Refactoring Plan

## Goal

Refactor the application's routing and controllers to follow the 37signals RESTful resource pattern from `docs/restful-resource-design.md`. Custom member/collection actions become focused, single-purpose controllers. This is primarily moving code around — no functionality changes.

## Current State

Several controllers have become "junk drawers" with custom actions:
- **ChatsController** — 10 custom member actions
- **AgentsController** — 7 custom actions (memories CRUD + telegrams + triggers)
- **MessagesController** — 2 custom actions (retry, fix hallucinations)
- **ApiKeysController** — 3 custom actions (approval flow)
- **UsersController** — 2 custom actions (password editing)
- **API::V1::ConversationsController** — 1 custom action (create_message)
- **Integration controllers** — OAuth callbacks + sync actions

## Sync Impact

Route changes do NOT affect ActionCable, model callbacks, or real-time synchronization. The sync system broadcasts model changes independently of routing, so this refactoring is safe.

## Frontend Impact

js-routes auto-regenerates when Rails routes change. All Svelte files using route helpers will need updated helper names. There are also ~40 hardcoded URL instances across 12 frontend files that should be migrated to route helpers during this refactor.

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
      resource :agent_assignment, only: :create           # assign single agent
      resource :agent_addition, only: :create             # add agent to group chat
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
| `Chats::AgentAdditionsController` | `create` | `chats#add_agent` |
| `Chats::AgentTriggersController` | `create` | `chats#trigger_agent` + `chats#trigger_all_agents` (distinguished by presence of `agent_id` param) |

### Shared Concern: `ChatScoped`

```ruby
# app/controllers/concerns/chat_scoped.rb
module ChatScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_account_and_chat
  end

  private

  def set_account_and_chat
    @account = current_user.accounts.find(params[:account_id])
    @chat = @account.chats.find(params[:chat_id])
  end
end
```

### Messages Index (older_messages)

Move the `older_messages` action into `MessagesController#index` under chats (the existing nested messages controller). The pagination logic stays identical — it returns messages before a given ID.

Current: `GET /accounts/:account_id/chats/:chat_id/older_messages?before_id=X`
New: `GET /accounts/:account_id/chats/:chat_id/messages?before_id=X`

### Frontend Updates (Phase 1)

Route helper renames:
- `archiveAccountChatPath` → `accountChatArchivePath`
- `unarchiveAccountChatPath` → remove (use DELETE on archive path)
- `discardAccountChatPath` → `accountChatDiscardPath`
- `restoreAccountChatPath` → remove (use DELETE on discard path)
- `forkAccountChatPath` → `accountChatForkPath`
- `moderateAllAccountChatPath` → `accountChatModerationPath`
- `assignAgentAccountChatPath` → `accountChatAgentAssignmentPath`
- `addAgentAccountChatPath` → `accountChatAgentAdditionPath`
- `triggerAgentAccountChatPath` → `accountChatAgentTriggerPath` (with agent_id param)
- `triggerAllAgentsAccountChatPath` → same path, no agent_id param
- `olderMessagesAccountChatPath` → `accountChatMessagesPath` (with before_id param)

Files to update:
- `app/frontend/pages/chats/show.svelte`
- `app/frontend/lib/components/chat/AgentTriggerBar.svelte`
- `app/frontend/pages/chats/ChatList.svelte`

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
      resources :memories, only: [:create, :destroy] do
        scope module: :memories do
          resource :discard, only: :destroy                     # undiscard (DELETE = restore)
          resource :constitutional, only: :update               # toggle constitutional flag
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
| `Agents::MemoriesController` | `create`, `destroy` | `agents#create_memory`, `agents#destroy_memory` |
| `Agents::Memories::DiscardsController` | `destroy` | `agents#undiscard_memory` |
| `Agents::Memories::ConstitutionalsController` | `update` | `agents#toggle_constitutional` |

### Shared Concern: `AgentScoped`

```ruby
module AgentScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_account_and_agent
  end

  private

  def set_account_and_agent
    @account = current_user.accounts.find(params[:account_id])
    @agent = @account.agents.find(params[:agent_id])
  end
end
```

### Frontend Updates (Phase 2)

Files to update:
- `app/frontend/pages/agents/edit.svelte` (hardcoded URLs + route helpers)

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

# Approval flow is a separate resource, keyed by token
scope "api_keys" do
  resources :approvals, only: [:show, :create, :destroy],
    param: :token, controller: "api_key_approvals"
end
```

This gives:
- `GET /api_keys/approvals/:token` — show approval form
- `POST /api_keys/approvals/:token` — approve
- `DELETE /api_keys/approvals/:token` — deny

### New Controller

| Controller | Actions | Replaces |
|---|---|---|
| `ApiKeyApprovalsController` | `show`, `create`, `destroy` | `api_keys#approve`, `api_keys#confirm_approve`, `api_keys#deny` |

### Frontend Updates (Phase 4)

- `approveApiKeyPath` → `apiKeyApprovalPath`
- `denyApiKeyPath` → same path, DELETE verb

Files to update:
- `app/frontend/pages/api_keys/index.svelte` (if it links to approval)
- `app/frontend/pages/api_keys/approve.svelte` (if it exists)

---

## Phase 5: UsersController (Password)

### New Routes

```ruby
resource :user, only: %i[edit update] do
  scope module: :users do
    resource :password, only: [:edit, :update]
  end
end

resource :user_avatar, only: %i[destroy], controller: "users", path: "user/avatar"
```

This gives:
- `GET /user/password/edit` → `Users::PasswordsController#edit`
- `PATCH /user/password` → `Users::PasswordsController#update`

### New Controller

| Controller | Actions | Replaces |
|---|---|---|
| `Users::PasswordsController` | `edit`, `update` | `users#edit_password`, `users#update_password` |

### Frontend Updates (Phase 5)

- `editPasswordUserPath` → `editUserPasswordPath`
- `updatePasswordUserPath` → `userPasswordPath` (PATCH)

Files to update:
- `app/frontend/pages/user/edit_password.svelte`
- `app/frontend/lib/components/forms/ChangePasswordForm.svelte`

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

---

## Phase 7: Integration Controllers (Lower Priority)

These are OAuth flows with conventions dictated by external providers. Lighter-touch refactoring.

### GitHub Integration

```ruby
resource :github_integration, only: %i[show create update destroy] do
  scope module: :github_integrations do
    resource :callback, only: :show           # OAuth callback (GET)
    resource :repository, only: [:new, :create]  # select_repo → new, save_repo → create
    resource :sync, only: :create             # manual sync trigger
  end
end
```

### Oura Integration

```ruby
resource :oura_integration, only: %i[show create update destroy] do
  scope module: :oura_integrations do
    resource :callback, only: :show           # OAuth callback (GET)
    resource :sync, only: :create             # manual sync trigger
  end
end
```

### Invitations (Resend)

```ruby
resources :invitations, only: [:create] do
  scope module: :invitations do
    resource :delivery, only: :create         # resend = create a new delivery
  end
end
```

---

## Implementation Approach

### For Each Phase:

1. **Create the new controller** — extract the action body from the existing controller
2. **Add the shared concern** (if needed) — `ChatScoped`, `AgentScoped`, etc.
3. **Update routes.rb** — replace custom actions with resource declarations
4. **Run `rails routes`** — verify new route names
5. **Update frontend** — replace old route helpers with new ones, convert hardcoded URLs
6. **Update tests** — adjust controller test paths and route assertions
7. **Run `rails test`** — verify nothing breaks
8. **Run `bin/rubocop`** — verify linting passes
9. **Remove old code** — delete custom actions from original controller

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

## Out of Scope

The following are intentionally left as-is:
- **RegistrationsController** — multi-step signup flow is conventional and doesn't benefit much from this pattern
- **Admin namespace** — already clean, no custom actions
- **Pages/Sessions controllers** — standard Rails auth patterns
- **Favicon/health routes** — utility routes, not domain resources

---

## DHH Review

### Overall Assessment

This is a strong plan that clearly understands the 37signals philosophy. The diagnosis is correct -- the ChatsController and AgentsController are textbook junk drawers, and the proposed extraction into focused resource controllers is exactly the right move. The phasing is sensible, the resource names are mostly well-chosen, and the plan correctly identifies that this is a code-organization refactor with no behavior changes. That said, there are several naming missteps, one semantic inversion that needs fixing, and a couple of places where the plan over-engineers what should be simpler.

### Critical Issues

**1. `Chats::AgentAdditionsController` is an awkward name for a clear concept**

"Agent addition" is not a noun that anyone would reach for. What you are really creating is a *participant* -- an agent joining a group conversation. Consider `Chats::ParticipantsController` instead. `POST /chats/:id/participant` reads as "add a participant to this chat." `resource :participant, only: :create` is clean and obvious. If you later need to remove agents from group chats, `destroy` slots in naturally.

**2. `Chats::AgentAssignmentsController` vs `Chats::ParticipantsController` -- these may be the same resource**

Looking at the actual code, `assign_agent` converts a model-based chat to an agent-based chat (sets `manual_responses: true`, adds the agent, posts a system notice). `add_agent` adds another agent to a group chat. Both actions ultimately add an agent to a chat's agents collection. The distinction is contextual, not structural. Consider whether a single `Chats::AgentAssignmentsController` could handle both cases, with the create action inspecting the chat state to determine behavior. Or, if the semantics truly diverge, keep them separate but rename `agent_addition` to `participant`.

**3. Memory discard semantics are inverted**

The plan maps `resource :discard, only: :destroy` to the `undiscard_memory` action. This reads as `DELETE /memories/:id/discard` meaning "restore." That is backwards. In the 37signals pattern, `POST /resource/discard` means discard, and `DELETE /resource/discard` means un-discard. But the existing `destroy_memory` action already *discards* (soft-deletes) the memory -- look at the controller: `memory.discard`. So the correct mapping is:

- `Agents::MemoriesController#destroy` should *not* hard-delete. It should soft-discard (as it does now).
- `resource :discard` with `create` (to discard) and `destroy` (to un-discard) replaces *both* `destroy_memory` and `undiscard_memory`.
- Drop the `destroy` action from `resources :memories` entirely, since memories are never hard-deleted.

The corrected routes:

```ruby
resources :memories, only: [:create] do
  scope module: :memories do
    resource :discard, only: [:create, :destroy]     # create = soft-delete, destroy = restore
    resource :constitutional, only: :update           # toggle constitutional flag
  end
end
```

This is more honest about what the application actually does. `POST /memories/:id/discard` discards. `DELETE /memories/:id/discard` restores. No confusion.

**4. `Agents::Memories::ConstitutionalsController` -- the name does not work as a noun**

"Constitutional" is an adjective, not a noun. You would not say "create a constitutional" or "update a constitutional." The resource here is a *protection* or a *lock*. Consider `resource :protection, only: [:create, :destroy]` -- `POST` to protect the memory, `DELETE` to unprotect. This also avoids the `update` verb for what is really a binary toggle, which is a smell. Toggles map cleanly to create/destroy on a state resource.

### Improvements Needed

**5. `ChatScoped` concern uses `current_user` but the app uses `Current.user`**

The existing `AccountScoping` concern references `Current.user`, not `current_user`. The `ChatScoped` and `AgentScoped` examples in the plan use `current_user.accounts.find(...)`. Verify which accessor the app standardizes on. Looking at the existing controllers, they use `current_account` from the `AccountScoping` concern. The new scoped concerns should likely delegate to `current_account` rather than re-implementing account lookup:

```ruby
module ChatScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_chat
  end

  private

  def set_chat
    @chat = current_account.chats.find(params[:chat_id])
  end
end
```

This is simpler and consistent with the existing `AccountScoping` concern that already handles `@account` via `current_account`.

**6. `resource :agent_trigger` conflates two distinct operations**

"Distinguished by presence of `agent_id` param" is a code smell in the 37signals pattern. The whole point is that the resource and the verb tell you what happens. If you need to inspect params to determine behavior, you have two resources wearing one controller's clothes. Consider:

```ruby
resource :agent_trigger, only: :create         # trigger specific agent (requires agent_id)
resource :agent_triggers, only: :create        # trigger all agents
```

Or more cleanly, since triggering all agents is conceptually different from triggering one:

```ruby
resources :agent_triggers, only: :create       # POST with agent_id triggers one
resource :agent_trigger_all, only: :create     # POST triggers all
```

Actually, the simplest approach: just use a single `resource :agent_trigger, only: :create` where no `agent_id` means "trigger all." This is a pragmatic compromise and the param check is minimal. The plan's current approach is acceptable here -- just document the convention clearly in the controller.

**7. The `user_avatar` route is a leftover that should be cleaned up in Phase 5**

```ruby
resource :user_avatar, only: %i[destroy], controller: "users", path: "user/avatar"
```

This is using the `UsersController#destroy` action to remove an avatar, which is semantically confused -- `destroy` on a user controller should destroy the user, not their avatar. In the refactored version, this should become:

```ruby
resource :user, only: %i[edit update] do
  scope module: :users do
    resource :password, only: [:edit, :update]
    resource :avatar, only: :destroy
  end
end
```

This gives `DELETE /user/avatar` handled by `Users::AvatarsController#destroy`. Clean, obvious, properly namespaced.

**8. Phase 4 API key approvals routing is unusual**

The `scope "api_keys"` with `resources :approvals` creates routes like `/api_keys/approvals/:token`. This works but the URL structure suggests approvals are a sub-resource of the api_keys collection, yet they are not nested under a specific api_key. Since approvals are keyed by token (not by api_key ID), this is actually a standalone resource that just shares the URL prefix for readability. The approach works, but consider the simpler alternative:

```ruby
resources :api_keys, only: [:index, :create, :destroy]
resources :api_key_approvals, only: [:show, :create, :destroy],
  param: :token, path: "api_keys/approvals"
```

Same URLs, but the routing declaration is more honest about the relationship. No functional difference -- just a minor clarity improvement.

**9. `resource :callback, only: :show` for OAuth is a stretch**

OAuth callbacks are GET requests with query params. Mapping them to `show` on a callback resource is technically valid but conceptually odd -- you are not "showing" anything, you are handling an OAuth code exchange. This is one of those cases where the external protocol's conventions are at tension with RESTful modeling. The plan acknowledges this with "lighter-touch refactoring," which is the right call. But consider whether the integration controllers are actually worth refactoring at all in this pass. They are small, focused on a single integration each, and the custom actions (`callback`, `sync`, `select_repo`, `save_repo`) are conventional in the OAuth world. Refactoring them buys little clarity and may confuse developers familiar with OAuth patterns. Recommend deferring or dropping Phase 7 entirely.

### What Works Well

**Phase 1 resource naming for chats.** `archive`, `discard`, `fork`, `moderation` -- these all read beautifully. `POST /chats/:id/archive` archives. `DELETE /chats/:id/archive` un-archives. `POST /chats/:id/fork` forks. This is exactly the 37signals pattern done right.

**The `older_messages` to `messages#index` mapping.** This is a textbook improvement. Paginated message listing is exactly what `index` is for. The `before_id` param is a clean cursor-based pagination approach.

**Phase 3 message sub-resources.** `retry` and `hallucination_fix` as singular resources on messages are well-named. `POST /messages/:id/retry` reads perfectly.

**Phase 5 password extraction.** `Users::PasswordsController` is the canonical Rails pattern. Clean and obvious.

**Phase 6 API nested messages.** `POST /api/v1/conversations/:conversation_id/messages` is exactly how a REST API should work. The current `create_message` custom action is the kind of thing that makes API consumers wince.

**The implementation approach.** The step-by-step checklist is thorough. The emphasis on "what does NOT change" is good -- it keeps the scope tight and reduces risk.

**The "out of scope" section.** Knowing what you are *not* changing is as important as knowing what you are changing. The justifications are sound.

### Summary of Recommended Changes

1. Rename `agent_addition` to `participant` (or unify with `agent_assignment`)
2. Fix the memory discard inversion -- `resource :discard, only: [:create, :destroy]` replaces both soft-delete and restore, drop `destroy` from `resources :memories`
3. Rename `constitutional` to `protection` and use `create`/`destroy` instead of `update`
4. Use `current_account` (from existing `AccountScoping`) in the new concerns instead of re-implementing account lookup
5. Extract the avatar into `Users::AvatarsController` instead of the current confused `user_avatar` route
6. Consider dropping or deferring Phase 7 (integration controllers) -- the ROI is low
