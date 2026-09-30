# DHH Review — RESTful Resource Refactoring (Round 1)

Feedback on `260211-restful-resource-refactoring.md` (first iteration).

## Overall Assessment

This is a strong plan that clearly understands the 37signals philosophy. The diagnosis is correct -- the ChatsController and AgentsController are textbook junk drawers, and the proposed extraction into focused resource controllers is exactly the right move. The phasing is sensible, the resource names are mostly well-chosen, and the plan correctly identifies that this is a code-organization refactor with no behavior changes. That said, there are several naming missteps, one semantic inversion that needs fixing, and a couple of places where the plan over-engineers what should be simpler.

## Critical Issues

**1. `Chats::AgentAdditionsController` is an awkward name for a clear concept**

"Agent addition" is not a noun that anyone would reach for. What you are really creating is a *participant* -- an agent joining a group conversation. Consider `Chats::ParticipantsController` instead. `POST /chats/:id/participant` reads as "add a participant to this chat." `resource :participant, only: :create` is clean and obvious. If you later need to remove agents from group chats, `destroy` slots in naturally.

**2. `Chats::AgentAssignmentsController` vs `Chats::ParticipantsController` -- these may be the same resource**

Looking at the actual code, `assign_agent` converts a model-based chat to an agent-based chat (sets `manual_responses: true`, adds the agent, posts a system notice). `add_agent` adds another agent to a group chat. Both actions ultimately add an agent to a chat's agents collection. The distinction is contextual, not structural. Consider whether a single `Chats::AgentAssignmentsController` could handle both cases, with the create action inspecting the chat state to determine behavior. Or, if the semantics truly diverge, keep them separate but rename `agent_addition` to `participant`.

**3. Memory discard semantics are inverted**

The plan maps `resource :discard, only: :destroy` to the `undiscard_memory` action. This reads as `DELETE /memories/:id/discard` meaning "restore." That is backwards. In the 37signals pattern, `POST /resource/discard` means discard, and `DELETE /resource/discard` means un-discard. But the existing `destroy_memory` action already *discards* (soft-deletes) the memory -- look at the controller: `memory.discard`. So the correct mapping is:

- `Agents::MemoriesController#destroy` should *not* hard-delete. It should soft-discard (as it does now).
- `resource :discard` with `create` (to discard) and `destroy` (to un-discard) replaces *both* `destroy_memory` and `undiscard_memory`.
- Drop the `destroy` action from `resources :memories` entirely, since memories are never hard-deleted.

**4. `Agents::Memories::ConstitutionalsController` -- the name does not work as a noun**

"Constitutional" is an adjective, not a noun. You would not say "create a constitutional" or "update a constitutional." The resource here is a *protection* or a *lock*. Consider `resource :protection, only: [:create, :destroy]` -- `POST` to protect the memory, `DELETE` to unprotect. This also avoids the `update` verb for what is really a binary toggle, which is a smell. Toggles map cleanly to create/destroy on a state resource.

## Improvements Needed

**5. `ChatScoped` concern should use `current_account`**

The existing controllers use `current_account` from the `AccountScoping` concern. The new scoped concerns should delegate to `current_account` rather than re-implementing account lookup.

**6. `resource :agent_trigger` conflates two distinct operations**

"Distinguished by presence of `agent_id` param" is a code smell. However, the simplest approach is acceptable here: just use a single `resource :agent_trigger, only: :create` where no `agent_id` means "trigger all." Document the convention clearly in the controller.

**7. The `user_avatar` route should be cleaned up in Phase 5**

Should become `Users::AvatarsController` nested under the user resource, not a confused separate route using `UsersController#destroy`.

**8. Phase 4 API key approvals routing**

Consider `resources :api_key_approvals` instead of `scope "api_keys"` with nested `resources :approvals`. More honest about the relationship.

**9. Drop Phase 7 (integration controllers)**

OAuth callbacks and sync actions are conventional. Refactoring them buys little clarity and may confuse developers familiar with OAuth patterns. Low ROI.

## What Works Well

- Phase 1 resource naming: `archive`, `discard`, `fork`, `moderation` read beautifully
- The `older_messages` to `messages#index` mapping is textbook
- Phase 3 message sub-resources: `retry` and `hallucination_fix` are well-named
- Phase 5 password extraction is canonical Rails
- Phase 6 API nested messages is exactly right
- Implementation approach is thorough
- "Out of scope" section is well-drawn
