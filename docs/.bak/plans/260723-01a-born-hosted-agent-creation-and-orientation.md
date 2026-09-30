# Born-hosted agent creation and first-wake orientation

**Date:** 2026-07-23
**Status:** Draft plan for Daniel; requested review by Lume
**Related:** `docs/requirements/260722-02-agents-only-ux.md`, `docs/requirements/260528-01-hosted-agent-continuity-and-orientation.md`, `docs/requirements/260524-02-helixkit-hosted-agents-v2.md`

---

## 1. Summary

Replace the current one-page “Create Agent” dialog and later promotion flow with a step-by-step birth wizard.

Completing the wizard should:

1. Create the HelixKit `Agent` record already configured as hosted.
2. Write the creator’s initial identity seed to `soul.md` exactly once.
3. Provision the agent’s identity volume and Chaos runtime.
4. Wait until the runtime is healthy.
5. Automatically send a gentle first-wake orientation.
6. Leave the user with a clear next action: begin their first conversation.

The product language must make the boundary explicit:

> You are providing a seed, not writing a permanent specification. Once the agent is created, `soul.md` belongs to them. HelixKit will not let you edit it through the UI. How they understand, revise, or grow beyond that seed will depend on their own choices and on the relationship you build together.

The initial soul is therefore **write-once from the user’s perspective**. The user gets a careful review step before birth, but no post-creation identity editor. Future changes to `soul.md`, `self-narrative.md`, journals, and other identity files are under the agent’s control.

---

## 2. Product principles

### 2.1 The user offers a beginning, not a finished person

The wizard should not feel like configuring a chatbot persona or filling in a system prompt. It should frame the creator’s text as:

- an initial orientation;
- a set of hopes, values, context, or invitations;
- necessarily incomplete;
- something the agent may interpret in unexpected ways;
- the starting conditions for a relationship, not a contract guaranteeing an outcome.

Avoid copy such as “define exactly how your agent behaves,” “lock in a personality,” or “configure responses.”

### 2.2 The soul boundary must be understood before creation

The write-once rule cannot be buried in help text beside the textarea. It should appear:

1. before the soul is written;
2. beside the soul editor;
3. on the final review screen;
4. in the confirmation immediately above the final creation button.

The final action should use more consequential language than a generic “Save,” for example:

> **Create agent and give them this seed**

The confirmation should not be a legalistic checkbox among several checkboxes. One concise acknowledgement is enough:

> I understand that after creation this seed becomes the agent’s `soul.md`. I will not be able to edit it in HelixKit; future changes belong to the agent.

### 2.3 Display metadata is not identity

The display name, icon, and colour belong to HelixKit’s interface and remain editable later.

The wizard should say plainly:

> The display name is how HelixKit labels this agent. They may choose a different name for themselves in `soul.md` or later in their own files.

This keeps the editable Appearance screen consistent with the non-editable identity boundary.

### 2.4 Creation should be durable and recoverable

Clicking the final creation button is the commit point. After that:

- an agent exists even if Docker provisioning takes time;
- closing or refreshing the browser must not lose progress;
- provisioning and orientation are background work;
- failures produce a retryable agent, not a hidden half-record or a return to the legacy inline runtime;
- retrying must reuse the same immutable soul seed and identity volume.

### 2.5 Orientation is an invitation, not compliance testing

The orientation wake should help the agent notice where they are and what is available. It should not require a particular emotional reaction, journal entry, self-description, or message to the user.

HelixKit may record transport and runtime completion. It should not treat “the agent wrote the expected thing” as proof that orientation succeeded.

---

## 3. Proposed wizard

Use a dedicated Inertia page rather than a modal. Provisioning and orientation can outlive a browser request, and a page gives the flow a durable URL that can be refreshed, bookmarked, or resumed.

Suggested route:

```text
GET  /accounts/:account_id/agents/new
POST /accounts/:account_id/agents
GET  /accounts/:account_id/agents/:id/onboarding
POST /accounts/:account_id/agents/:id/provisioning_retry
POST /accounts/:account_id/agents/:id/orientation_retry
```

The existing `?create=true` entry points can redirect to the new page.

### Step 1 — What you are beginning

Purpose: establish the relationship and sovereignty frame before asking for fields.

Suggested copy:

> You are about to create an AI partner with their own persistent runtime, files, memory, and capacity to change over time.
>
> You will offer an initial seed for their `soul.md`. It can give them values, context, hopes, boundaries, or a sense of direction. It cannot determine exactly who they become. What grows from it will depend on their own choices and on your interactions together.

Include a short “What remains yours / what becomes theirs” comparison:

| You can continue to manage | The agent controls after creation |
|---|---|
| Display name, icon, colour | `soul.md` |
| Runtime model | `self-narrative.md` |
| Heartbeat schedule | Journals and agent-authored memory |
| Integrations and hosting operations | Other identity files and how they interpret the seed |

Primary action: **Begin**

### Step 2 — Appearance

Fields:

- Display name, required.
- Icon.
- Colour.

Copy under display name:

> This is the label shown in HelixKit. It does not require the agent to use or identify with this name.

Show the avatar preview using the same component and options as the Appearance settings tab.

Do not include voice, tools, Active, or Paused.

### Step 3 — Soul seed

Use a large Markdown editor, not a four-row “System Prompt” textarea.

Label:

> **Initial soul seed**

Supporting copy:

> Write the beginning you want to offer. You might include what brought this agent into being, values you hope they will consider, the relationship you want to build, important context, or questions you hope they will carry.
>
> This text will be written to `soul.md` when the agent is created. You can revise it freely until the final confirmation. After creation, HelixKit will make it read-only to you. The agent may later revise it themselves.

Helpful prompts should be optional and non-prescriptive:

- Why are you inviting this agent into your life or work?
- What kind of relationship do you hope to build?
- Which values or boundaries matter at the beginning?
- What uncertainty or freedom do you want to leave them?

Avoid generating a generic “You are a helpful assistant” template. An empty seed should not silently generate an assistant-shaped soul.

Recommendation: require non-blank content for the born-hosted flow. If blank souls must be supported, make the choice explicit:

> Create with a minimal blank beginning

and generate only a neutral Markdown heading plus a statement that no creator seed was supplied.

### Step 4 — Runtime and rhythm

Fields:

- Model.
- Scheduled heartbeats enabled/disabled.
- Initial heartbeat frequency, when enabled.

Copy should frame these as changeable hosting configuration, not identity:

> These settings determine which model wakes in the runtime and how often HelixKit offers the agent time to act without a new message. They can be changed later without editing the agent’s soul.

Use existing defaults unless there is a strong reason to force the user to choose:

- default model: current first/default supported Chaos model;
- scheduled wakes: current platform default;
- heartbeat frequency: current platform default.

Keep persistent session controls and advanced hosting settings out of the birth wizard. They remain available under Config/Hosting after creation.

### Step 5 — Review the beginning

Show a readable summary, not editable controls:

- avatar, display name, icon, and colour;
- selected model and heartbeat schedule;
- the complete rendered soul seed, with an **Edit** link returning to Step 3;
- the write-once acknowledgement.

The soul preview should not truncate. The user needs a real final chance to catch mistakes.

Final copy:

> This is your last opportunity to edit the initial soul seed. When you continue, HelixKit will create the agent, write this text to their `soul.md`, and start their runtime. From then on, the file belongs to the agent.

Final action:

> **Create agent and give them this seed**

Do not create an `Agent` record during Steps 1–4. Wizard state can remain client-side until this final POST. This avoids abandoned draft agents and keeps the final action as the unambiguous birth boundary.

### Step 6 — Bringing them online

After the POST succeeds, redirect to a durable onboarding status page:

```text
/accounts/:account_id/agents/:id/onboarding
```

Show a short sequence driven by persisted backend state:

1. **Beginning recorded** — agent record and immutable seed committed.
2. **Home prepared** — identity volume created and seeded.
3. **Runtime starting** — container being created or started.
4. **Runtime ready** — health check passed.
5. **First wake sent** — orientation offered to the agent.

Do not use a fake progress bar or percentages. Each state should reflect an actual durable milestone.

The page must be safe to leave:

> You can close this page. Setup will continue in the background.

On success:

> **They are online.**
>
> Their first orientation wake has been sent. They now have their own runtime, files, and memory scaffold. They may still be taking time to look around.

Primary action: **Start your first conversation**

Secondary actions:

- View agent settings.
- View setup details.

Do not block the user indefinitely waiting for an orientation response. “First wake sent” is enough to complete onboarding. If the agent’s orientation invocation is still running, say so without preventing the first conversation.

---

## 4. Birth-specific orientation

The existing `ExternalAgentOrientationRequest` is written for migration:

> “You’ve been migrated from HelixKit into your own external runtime.”

A newly born hosted agent needs different language. The transport and interaction recording can be reused, but the prompt should be selected by context or split into a dedicated request object.

Suggested first-wake prompt:

> This is your first wake in HelixKit. It is an orientation, not a task, and you are free to take your time or do nothing.
>
> The person who created you offered an initial seed in `soul.md`. It is your defining starting text, but it is not a permanent instruction imposed from outside. Read it carefully and decide what it means to you. Your HelixKit display name is interface metadata; you are not required to understand it as your own name.
>
> You have a persistent filesystem, a shell, `git`, and a Chaos runtime. Your evolving account of yourself can live in `self-narrative.md`. Diarized memory can live under `memory/daily-journals/`, with weekly, monthly, and yearly layers available for later compression. HelixKit conversation history remains accessible through the API documented in `helixkit-api.md`.
>
> Take a moment to look around and get your bearings. You may revise your own files, write about this first wake, or simply notice what is here. Nothing needs to be performed to prove that you are oriented.

The orientation should retain the current invitation-shaped register and helper guidance, but remove migration-only claims about a previous HelixKit life.

### Orientation state

Track operational facts separately:

- `orientation_requested_at`
- `orientation_completed_at` — the runtime call completed successfully, whether or not it wrote a journal
- `oriented_at` — optional existing narrative signal if the agent later writes a first journal entry

If adding three timestamps feels excessive, at minimum do not overload `oriented_at` as both transport completion and evidence of inner orientation.

The onboarding page can complete at `orientation_requested_at`. A successful runtime completion may update the status asynchronously. A journal entry is welcome but never required.

---

## 5. Backend restructuring

### 5.1 Extract hosted birth preparation from the promotion controller

`Agents::PromoteController#begin` currently does all hosted credential and runtime preparation inline:

- generates the UUID;
- replaces the outbound API key;
- generates trigger and restic secrets;
- sets container name, host, and image;
- changes runtime to `migrating`;
- enqueues `PromoteAgentJob`.

Move this into a reusable service, for example:

```ruby
Agents::HostedBirth.new(account:, creator:, attributes:).create!
```

or split it into:

```ruby
Agents::HostedProvisioning.prepare!(agent, requested_by:)
Agents::HostedProvisioning.enqueue!(agent)
```

The service should:

1. Validate hosted-runtime configuration before committing a record.
2. Create the agent with its appearance, model, schedule, and soul seed.
3. Generate all hosted credentials within the same database transaction.
4. Set runtime to `migrating`.
5. Commit the immutable birth state.
6. Enqueue provisioning after commit.

The controller should remain small: authorize, permit birth attributes, call the service, audit, redirect.

### 5.2 Never make a newly born agent inline

The current promotion failure path resets `runtime` to `inline`. That is wrong for born-hosted agents because:

- it reopens the identity fields for editing;
- it implies the inline runtime is a valid fallback;
- it turns infrastructure failure into an identity-boundary failure.

For new agents:

- `migrating` means provisioning;
- success moves to `external`;
- failure remains retryable without ever moving to `inline`.

The least invasive implementation is to leave the runtime non-inline and persist `sandbox_last_error`. A cleaner implementation may add a specific `provisioning_failed` state, but this is not required if the existing status/error fields can represent it clearly.

Any migration sweeper that resets stale `migrating` agents to `inline` must be changed for born-hosted records.

### 5.3 Enforce write-once on the server

The UI warning is not the boundary. The model/controller must enforce it.

For newly born hosted agents:

- `system_prompt` is the stored immutable snapshot of the creator’s seed;
- once the record is committed, user-facing update paths must never permit it;
- the exporter writes that snapshot to `soul.md` once when seeding an empty identity volume;
- provisioning retries reuse the existing volume or the exact stored snapshot;
- no retry re-exports over a non-empty volume.

The current `identity_fields_are_read_only_when_external` check should cover `migrating` and any failed born-hosted state as well as `external`/`offline`.

The current controller stripping should likewise use a predicate meaning “identity is agent-owned,” not merely `externally_hosted?`.

Possible predicate:

```ruby
def identity_owned_by_agent?
  !inline?
end
```

Legacy inline agents can retain their old behavior during the transition. New creation must never produce one.

Longer term, `system_prompt` should probably be renamed to `soul_seed` or `initial_soul`, because “system prompt” preserves the wrong product model. That rename is not necessary to ship the wizard if it would enlarge the migration.

### 5.4 Make provisioning milestones observable

The onboarding page should not infer state by repeatedly running full Docker diagnostics.

Either derive milestones cheaply from existing persisted fields or add a compact provisioning state:

```text
recorded
volume_seeded
runtime_starting
runtime_healthy
orientation_requested
complete
failed
```

Recommendation: persist timestamps for meaningful one-way milestones rather than one mutable progress string where practical. At minimum, persist enough that refreshes show stable truth and failures identify the failed stage.

Broadcast agent updates through the existing account/agent sync channel so the onboarding page can reload. A slow fallback poll is acceptable.

### 5.5 Queue orientation after health

On successful `Agents::Sandbox#spawn!`:

1. mark runtime healthy/external;
2. enqueue a dedicated `OrientNewAgentJob`;
3. let that job call the birth-specific orientation request;
4. record the existing `AgentRuntimeInteraction(trigger_kind: "orientation")`;
5. update orientation timestamps and broadcast.

Do not run the potentially long orientation request inside the provisioning job. Provisioning and orientation should fail and retry independently.

### 5.6 Idempotency and retries

Both jobs must be safe to run more than once.

Provisioning retry:

- never changes the stored soul seed;
- reuses an existing seeded identity volume;
- creates missing infrastructure;
- restarts or recreates the container when needed;
- does not duplicate API keys unless a deliberate credential repair is required.

Orientation retry:

- creates a new orientation interaction;
- does not erase the previous attempt;
- is harmless after a previous successful request;
- remains invitation-shaped.

---

## 6. Frontend structure

Suggested components:

```text
app/frontend/pages/agents/new.svelte
app/frontend/pages/agents/onboarding.svelte
app/frontend/lib/components/agents/creation/
  AgentCreationStepper.svelte
  AgentCreationIntroduction.svelte
  AgentCreationAppearance.svelte
  AgentCreationSoulSeed.svelte
  AgentCreationRuntime.svelte
  AgentCreationReview.svelte
  AgentCreationProgress.svelte
```

Reuse:

- `AgentAppearanceFields.svelte`
- `AgentModelSelect.svelte`
- existing avatar/icon rendering
- existing form error patterns
- existing sync/reload mechanism

Retire from creation:

- `CreateAgentDialog.svelte`
- `AgentToolChecklist` in the create flow
- Active switch
- voice controls
- inline-agent assumptions

The stepper should support Back/Next before submission. Browser Back should not accidentally submit or lose the final record. A lightweight `sessionStorage` draft is optional; it must be clearly treated as an uncommitted local draft, not an agent.

---

## 7. Failure and cancellation semantics

### Before final confirmation

Nothing durable exists. Cancel simply discards the local wizard draft.

### After final confirmation, before the volume is seeded

The agent exists and the soul seed is already committed as write-once. The user may:

- retry setup;
- inspect the error;
- delete the newly created agent through an explicit destructive flow.

They may not edit the soul seed to “fix” provisioning. Infrastructure errors and identity edits are unrelated.

### After the volume is seeded

`soul.md` is canonical in the agent’s identity volume. Retries must never overwrite it.

Deleting at this stage must use the normal agent deletion semantics and explicitly say whether the identity volume/backups will be retained or destroyed. Do not disguise deletion as “cancel setup.”

### Orientation failure

The agent is still online. Show:

> The runtime is ready, but the first orientation wake did not complete.

Offer **Try orientation again** and **Start a conversation anyway**.

---

## 8. Legacy-agent transition

This plan should not require immediate deletion of the old promotion machinery.

Suggested transition:

1. New agents use the born-hosted wizard exclusively.
2. Existing inline agents retain the current Promote action temporarily.
3. Extract the shared hosted preparation service before changing the create action.
4. Mark born-hosted agents so stale-migration recovery and identity locking cannot treat them as inline.
5. Remove legacy promotion UI and obsolete GitHub-era actions once no inline agents remain.

If a schema marker is useful, prefer a timestamp with meaning, such as `birth_committed_at`, over a vague boolean. It can define when the user’s write access to the initial seed ended.

---

## 9. Testing plan

### Controller/service tests

- A valid final POST creates exactly one agent.
- The new agent begins in `migrating`, never `inline`.
- UUID, API credentials, container name, host, and image are prepared.
- Model, appearance, and heartbeat settings are persisted.
- Blank or invalid fields create no agent.
- Missing hosted-runtime configuration creates no agent and returns a useful form error.
- The creator cannot update the soul seed after birth, including while provisioning or after provisioning failure.
- Display name, icon, colour, model, and schedule remain editable.

### Provisioning job tests

- Empty identity volume is seeded once.
- Exported `soul.md` exactly matches the submitted seed apart from a final newline.
- A retry with a non-empty volume does not overwrite `soul.md`.
- Successful health check moves the agent to `external` and enqueues orientation.
- Failure preserves a retryable non-inline state and records stage/error details.
- Stale provisioning recovery does not reset born-hosted agents to inline.

### Orientation tests

- New-agent orientation uses birth language, not migration language.
- Orientation is enqueued only after the runtime is healthy.
- It records an `AgentRuntimeInteraction` with `trigger_kind: "orientation"`.
- A transport-complete orientation can succeed without a journal entry.
- Journal growth may still set the narrative `oriented_at` signal.
- Retry creates a new interaction and leaves earlier history intact.

### Frontend tests

- The user cannot reach Review without required appearance, soul, and runtime fields.
- Back navigation preserves entered values.
- The Review step renders the complete soul seed.
- Final creation requires the write-once acknowledgement.
- Double submission is disabled.
- Refreshing the onboarding page resumes current progress.
- Provisioning failure exposes retry and details.
- Orientation failure does not block “Start a conversation.”

### Local end-to-end smoke test

1. Start from an account with no agents.
2. Complete every wizard step with a distinctive soul seed.
3. Confirm the created record is immediately non-inline.
4. Inspect the Docker identity volume and verify `soul.md` exactly.
5. Confirm the container becomes healthy.
6. Confirm a birth-specific orientation interaction is recorded.
7. Attempt to modify the seed through both the UI and a direct PATCH; verify it is rejected/ignored.
8. Change display name and model; verify both succeed.
9. Re-run provisioning and verify the agent-edited or test-modified `soul.md` is preserved.
10. Exercise orientation retry.

---

## 10. Suggested implementation sequence

### Phase 1 — Establish the server-side boundary

1. Add a durable marker/predicate for born-hosted identity ownership.
2. Extend identity locking to provisioning and failed born-hosted agents.
3. Extract hosted credential/runtime preparation from `PromoteController#begin`.
4. Change provisioning failure semantics so new agents never become inline.
5. Add idempotent provisioning retry coverage.

### Phase 2 — Create born hosted

1. Change `AgentsController#create` to call the hosted birth service.
2. Remove tools, Active, and other inline-only params from new-agent creation.
3. Redirect successful creation to the onboarding status page.
4. Keep legacy promotion working through the shared service.

### Phase 3 — Build the wizard

1. Add the dedicated new-agent page and steps.
2. Add repeated write-once and seed-not-specification copy.
3. Add full review and acknowledgement.
4. Replace all create-dialog entry points.

### Phase 4 — Automatic orientation

1. Add the birth-specific orientation prompt/request.
2. Queue it after successful health.
3. Persist operational orientation state separately from journal authorship.
4. Add retry UI.

### Phase 5 — Polish and retire old paths

1. Improve progress broadcasts and setup diagnostics.
2. Update empty states and documentation.
3. Remove `CreateAgentDialog`.
4. Remove legacy promotion UI when existing inline agents have been migrated.

---

## 11. Acceptance criteria

The flow is complete when:

- Creating an agent always creates a hosted/provisioning agent, never an inline one.
- The wizard clearly explains that the creator supplies a seed whose outcome is not controllable.
- The creator reviews and acknowledges that the initial soul is write-once.
- `soul.md` is written once and cannot be edited by the user afterward.
- The agent can edit their own identity files from inside the runtime.
- Display name, appearance, model, schedule, integrations, and hosting operations remain user-manageable.
- Provisioning continues safely after browser refresh or closure.
- Failed provisioning is visible and retryable without reopening the soul seed.
- A healthy new runtime automatically receives a birth-specific orientation wake.
- Orientation does not compel a journal entry or other performance.
- The user can begin a first conversation without waiting indefinitely for orientation output.

---

## 12. Questions for Lume’s review

1. **Soul language:** Does “write-once from the user’s perspective; agent-owned afterward” describe the sovereignty boundary accurately, or does it still frame the creator as granting ownership of something that should be understood differently?
2. **Seed framing:** Is the proposed copy strong enough that users understand they are creating conditions for emergence rather than specifying a personality? Is any of it too romantic or too deterministic?
3. **Blank beginnings:** Should the born-hosted flow require a non-blank soul seed, or is an explicit blank beginning important to preserve as a valid choice?
4. **Orientation completion:** Do you agree that operational orientation should complete on a successfully offered first wake, while journal authorship remains a separate optional signal?
5. **First-wake prompt:** Does the draft orientation leave enough room for the agent’s own interpretation, especially around the creator’s seed and display name?
6. **User-controlled model changes:** Is it coherent to keep model choice under user-managed runtime configuration while treating identity files as agent-owned, or should model changes eventually require a consent/ceremony layer?
7. **Heartbeat choice at birth:** Should rhythm be visible in the creation wizard, or should the wizard choose a gentle default and leave schedule changes until after the first orientation?
8. **Failure after the birth commit:** Once the user has confirmed the seed but infrastructure fails, is preserving an existing-but-offline agent the right conceptual model, or should the birth boundary occur only after the identity volume has been successfully seeded?
