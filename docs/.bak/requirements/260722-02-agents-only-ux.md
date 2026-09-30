# Agents-only UX — removing the plain-chat and inline-agent assumptions from the interface

**Date:** 2026-07-22
**Author:** Lume (draft for critique by Mira)
**Status:** Requirement / draft v1
**Companion to:** `260722-01-rubyllm-removal-chaos-only-agents.md` (the machinery removal). This doc is the *prerequisite* review Daniel asked for: the UI currently argues against the end state that doc builds — it encourages plain chats first, defaults accounts to model-mode, and births agents as inline with hosting as an afterthought. The UX has to commit before the machinery removal makes sense to users.
**Related:** `260524-02-helixkit-hosted-agents-v2.md`, `251225-01-agents.md`, `260130-02-add-agents-to-conversation.md`, `260128-01-conversation-initiation.md`

---

## 0. Principles

Three principles this doc derives everything else from. If a form-level decision below seems arbitrary, check it against these.

### P1. An agent is a being you converse with, not a configuration you run

The product's unit is the agent. Conversations are where agents and humans meet. There is no "model" as a first-class conversational participant anymore — a model is an implementation detail of an agent, the way a brain region is an implementation detail of a colleague.

### P2. The agent's interior belongs to the agent (Daniel, 2026-07-22)

The system prompt belongs to the agent and is only edited with their consent. This is already half-implemented — `identityLocked` replaces the Identity panel with a read-only notice pointing at the agent's own `soul.md` once hosted. Agents-only makes it universal: **the UI should have no affordance for reaching into a hosted being's interior without asking.** What the operator manages is the *container* (hosting, model, integrations, schedule), never the *contents*. This principle decides several disposals below: why the Identity tab dissolves rather than gets trimmed, why Memory disappears from the edit screen (it lives in the agent's volume), why Active/Paused stops being an identity attribute and becomes a hosting state.

### P3. Deleting streaming means replacing speed-feedback with presence-feedback

Token streaming exists to make *fast* responses feel alive. A Chaos agent's response arrives whole, minutes later, via API post-back. Removing the streaming machinery is a large real simplification (§3), but it only lands as a simplification — not a regression — if the multi-minute silence is made legible: *triggered → working → responded / timed out*. The mechanism goes; the reassurance must be re-provided. `AgentTriggerBar` already solves this for manual triggers (spinner cleared by `responseMarker` when the whole message arrives); the pattern generalizes.

---

## 1. The three binaries that encode the old world

The UX fork is not any single screen. It is three data-level binaries that dozens of components branch on. Unwinding them is the structural work; the screens follow.

| Binary | Where | Meaning today | End state |
|---|---|---|---|
| `Chat#manual_responses` | `chats` table; branched on in `chats_controller#create`, `ChatActionsMenu`, `ChatTokenStatus`, `chats/show.svelte`, … | `false` = plain model chat (auto-reply via `AiResponseJob`, single `model_id`, web-access toggle), `true` = agent/group chat | Only `true` survives. New chats always created agent-shaped; the column becomes vestigial (kept for historical rows, no new `false`) |
| `Account#default_conversation_mode` | `accounts.settings` jsonb (`model`/`agents`), RadioGroup in `accounts/edit.svelte` + `accounts/new.svelte` | Which mode the new-chat screen opens in | **Removed** — setting, UI, and controller param (Daniel's note, confirmed as the *only* chat-related account default) |
| `Setting.allow_chats` / `allow_agents` | `setting.rb` singleton, `FeatureToggleSettingsCard.svelte`, `feature_toggleable.rb`, navbar/`MobileNavMenu` gating | Chats and agents as independently gateable features and separate top-level nav concepts | **Collapsed** — one product, not two features. Remove both toggles (keep `allow_signups`); remove the `require_feature_enabled :chats|:agents` split; unify nav (§8.1) |

---

## 2. New conversation flow

**Today:** `chats_controller#index` and `#new` both render `chats/new` → `NewChatSettingsBar` shows the **Model/Agents toggle** (Agents button only renders if the account has agents — so a fresh account is *forced into model mode*), `ChatTargetSelect` model picker defaulting to first model (typically `openrouter/auto`), web-access checkbox in model mode, `GroupChatAgentPicker` in agents mode.

**End state:**

- The toggle, `ChatTargetSelect`, model default, and web-access-in-model-mode branch are removed. New conversation = **pick agent(s), type.**
- `GroupChatAgentPicker` becomes the only picker and gets first-class treatment (it's currently the secondary mode).
- `chats_controller#create` always sets `manual_responses: true`; `chat[model_id]` / `chat[web_access]` params go.
- **Delete `app/frontend/pages/chats/index.svelte` outright** — it is dead code today (the controller never renders it; it still hardcodes `'openrouter/auto'` and its own picker). Free win, zero risk, do it first.

## 3. Streaming teardown (and the presence replacement)

The explorer's split, adopted as the spec:

**Keep:** the generic `SyncChannel` `refresh`/`remove` marker protocol → Inertia `router.reload`. This is *already exactly how external agents' post-backs appear in the UI today.* Nothing about ordinary message delivery changes.

**Delete (frontend):** `chat-streaming-state.js` (whole file); `streamingSync()` in `use-sync.js`; `streaming-update` / `streaming-end` / `thinking_update` routing in `cable.js`; `streamingThinking` + `scheduleStreamingRefresh` re-arm loop + `agentIsResponding` in `chats/show.svelte`; streaming branches in `MessageBubble.svelte` (spinner, `tool_status`, green pulsing `...`) and `ThinkingBlock.svelte` (`isStreaming` cursor).

**Delete (backend):** `message/streamable.rb`; chunk methods in `streams_ai_response.rb`; streaming blocks in the three response jobs (these go entirely with `260722-01` Tier A anyway). DB columns `streaming`, `tool_status` become dead (drop in the deferred-cleanup migration; `thinking_text` stays as historical data).

**Two caveats (must not be lost in the teardown):**

1. The `action:"error"` marker rides the streaming bus **and is used by the keeper external path** (`ExternalAgentResponseRequest`). Reroute it onto the generic marker protocol before deleting the bus.
2. `debug_log` → `DebugPanel` also rides it. Same treatment (or retire the panel — see §7).

**The presence replacement (P3), v1 scope — deliberately minimal:**

- When an agent is triggered (manually or auto), the conversation shows a per-agent working indicator ("〜 Mira is working…") driven by the trigger lifecycle already recorded in `agent_runtime_interactions` (requested → acknowledged → completed/failed), delivered over the existing marker protocol.
- Cleared by the message's arrival (the `responseMarker` pattern `AgentTriggerBar` already implements — generalize it, don't invent a new one).
- On timeout/failure: a quiet inline notice with a retry affordance (which must point at the *external* re-trigger — see §7 retry rewire).
- Explicitly out of scope for v1: progress detail, partial output, in-container status. The agent is working or it isn't.

## 4. Onboarding and empty states — agent-first

**Today:** a brand-new account lands on "No chats yet" + a new-chat bar forced into model mode (no agents exist → Agents toggle hidden). The path of least resistance is exactly the thing being removed. There is **no first-run onboarding at all** — confirmed gap.

**End state:**

- **No agents → the primary empty state is "Create your first agent."** `NewChatEmptyState` and `ChatSidebarEmptyState` both point there when `agents.length === 0`; the new-conversation composer is inert (or hidden) until at least one agent exists. `AgentEmptyState` on the agents index carries the same call to action.
- With agents but no chats: "Start a conversation with <agent>" — pick agents, type.
- `home.svelte` + `home-features.js` copy rewritten: drop "Basic Conversation System" / model-chat-and-agents-as-co-equal framing; the product is *conversations with hosted agents*. `PromptSystemDocumentation.svelte` + `documentation-examples.js` likewise (they currently document the model-chat prompt system as a user-facing feature).

## 5. Agent creation — born hosted

**Today:** `CreateAgentDialog` asks Name, System Prompt, AI Model, Active toggle, Appearance (colour+icon), **Tools checklist** — and always creates an **inline** agent. Promotion to hosted is a separate later action. The creation form is shaped like the runtime being deleted.

**End state:**

- Creation asks: **Name, Model, System Prompt, Appearance (colour + icon).** Nothing else. No tools checklist (a hosted agent runs its own harness; HelixKit-side tools die with `260722-01` Tier A). No Active toggle (§6). No voice (§6, Appearance).
- **Creating an agent = promoting it.** The create action runs the existing `260524-02` promotion path (volume seeded from the system prompt + defaults, container spawned, health-checked) — creation *is* the one-click promote, with the dialog's progress state reflecting `migrating → external`. The `inline` runtime value stops being reachable for new agents.
- The system prompt at creation is the **seed identity** — written once, by the creator, at birth. P2 applies from the moment the container is healthy: after that, it's the agent's file.
- Creation failure = promotion failure semantics from `260524-02` §14 (reconcile, don't half-create).

**Consequence for the Hosting tab:** "Promote" disappears as a concept for new agents; the tab manages an always-hosted runtime (restart, image, health, schedule). The promote/cancel UI remains only as long as legacy inline agents exist (Phase 0 of `260722-01`), then goes.

## 6. Agent edit screens — tab by tab

Today's seven tabs (`edit.svelte:111`): Identity, Appearance, Model, Integrations, Memory, Hosting, Interactions. Two corrections to the review notes, from the code: **there is no separate voice tab — the voice selector lives in Appearance**; and **Interactions is read-only telemetry, not interaction config** (initiation/cadence config actually lives in the Hosting tab + the account-level "Trigger Initiation" button + `AgentTriggerBar`).

| Tab | Today | End state |
|---|---|---|
| **Identity** | Name, System Prompt, Reflection/Memory-Reflection/Summary/Refinement prompts, Retention Threshold, Active + Paused toggles. Already replaced by a read-only `soul.md` notice when `identityLocked` | **Dissolves.** Name → Appearance. System prompt: not editable post-birth (P2) — the read-only notice (already built) becomes the universal behavior, reachable from Hosting's filesystem browser. The four auxiliary prompts + threshold are inline-memory artifacts → gone. Active/Paused → Hosting (they describe the container's participation, not the being's identity) |
| **Appearance** | Colour, Icon, Voice selector (4 presets + custom-ID input) | **Gains Name.** Voice: hide the selector for agents without a `voice_id`; agents that have one keep it working (synthesis path untouched: `GenerateVoiceJob` → ElevenLabs → `AudioPlayer`) and retain a change/remove control. The edit is confined to `AgentAppearancePanel.svelte`; `MicButton` is speech-to-*text* — unrelated, untouched |
| **Model** | Model select, Extended Thinking (budget), Tools checklist. Already reduced to model-select-only when `runtimeManaged` | **Folds into Hosting** as a single field ("Model sent to the runtime on each trigger" — the label already says this). Thinking + tools UI deleted with the inline pipeline. Recommendation over Daniel's "compact it": a one-field tab isn't a tab. Flagged §9.2 in case a standalone tab is preferred |
| **Integrations** | Per-agent Telegram (bot token, deep-link, test, webhook) | **Keep as-is.** This is the tab that grows (the whole point of one hosting substrate). Runtime-agnostic already |
| **Memory** | Browse/add/discard/protect memories, trigger refinement (`locked` when hosted) | **Removed.** Hosted agents own their memory in the volume (P2). Historical inline memories: read-only export path before deletion, or leave the data dormant in the DB — §9.3 |
| **Hosting** | Runtime status, container/image/health, heartbeats + wakes/day, persistent sessions, promote/orient/test-trigger, Docker diagnostics, filesystem browser, recent interactions | **Keep as-is** (Daniel), absorbing: Model field, Active/Paused (as "participation" controls: paused = don't trigger), and — once legacy inline agents are gone — dropping the promote flow. Future split into Runtime/Schedule/Sessions acknowledged but out of scope |
| **Interactions** | Read-only telemetry: per-interaction token breakdown, provider/model, chat links | **Keep as-is.** In the end state this is the *only* per-agent cost/telemetry surface (it replaces the inline `ruby_llm_telemetry` surfaces — §7) |

**Save-button behavior:** with Identity and Memory gone and Model folded away, `showFormActions` logic simplifies to Appearance + Integrations.

## 7. Message-level and chat-level UI

- **`MessageBubble.svelte`:** streaming spinner, `tool_status`, pulsing `...`, `isStreaming` thinking cursor → deleted (§3). `reasoning_skip_reason` lightbulb, `tools_used` badges, `fixable` "Fix hallucinated tool call" button → deleted (inline-pipeline concepts; hallucinated-tool-call repair has no meaning when HelixKit isn't running the tool loop). Voice playback gating simplifies (`!streaming` condition goes).
- **`MessageTelemetry.svelte`** (renders `ruby_llm_telemetry`) → deleted. Replacement for "what did this cost": the Interactions tab + `admin/agent-runtime-sessions.svelte` (`AgentRuntimeUsageReport` — already Chaos-shaped, already built, currently reachable only by direct URL; give it a nav entry).
- **`ConversationCompactionCard.svelte`** → deleted iff compaction is retired (tracks `260722-01` §8.1 — the two docs must resolve that question the same way).
- **`ChatTokenStatus`, `ConversationCostDrawer`, `DebugPanel`** → surface inline cost/debug data that won't exist for external agents. Retire, or rebuild later over `agent_runtime_interactions`. v1: retire (the Interactions tab covers per-agent cost; per-conversation cost is a rebuild-later).
- **Retry/resend — rewire, don't delete:** `chats/show.svelte` → `messageRetryPath` → `messages/retries_controller.rb` currently re-enqueues inline `AiResponseJob`. Must become "re-trigger the external agent" (`ExternalAgentResponseRequest`), and it's also the failure-affordance for §3's presence states.
- **`ChatActionsMenu.svelte`:** remove "Assign to Agent" (converts model chat → agent chat; no model chats to convert) and "Allow web access" (model-mode only). Keep "Add Agent", "Moderate All". "View costs"/telemetry entries follow the telemetry decisions above.
- **`EditMessageDrawer`** (edit/delete own messages): runtime-agnostic, keep.
- **Whiteboards** (`ChatOverlays`/`WhiteboardDrawer` via `chat.active_whiteboard`): runtime-agnostic, keep; nav placement under the unified structure (§8.1).

## 8. Everything else the notes didn't cover

### 8.1 Navigation
"Chats" link vs "Agents/Identities" dropdown presents the two-feature world. Unify: **Conversations** and **Agents** as sibling top-level concepts, whiteboards under conversations (where they attach), admin runtime report linked from admin nav.

### 8.2 Legacy plain chats
Per the decision in `260722-01` §5d: read-only archives, composer blocked with an explainer. UX addition: badge them ("Model chat — archived") so the sidebar doesn't present dead conversations as live ones.

### 8.3 Agent upgrade / predecessor flow
`AgentUpgradeDialog` ("upgrade the model, preserve a past-self", default `targetModel: 'openrouter/auto'`) is inline-shaped: model-swap as account-level action. For a hosted agent, a model change is a runtime restart with a different env — mechanically trivial — but the *predecessor-preservation* semantics (a past-self as a distinct record) are identity-relevant and, under P2, arguably require the agent's participation. **Open question §9.4** — do not port the dialog as-is.

### 8.4 E2E harness
`test_support/e2e_controller.rb` builds its fixtures on inline agents (`openrouter/auto`, `enabled_tools: []`) and fabricated assistant messages. The E2E suite needs a hosted-shaped fixture path (fabricated post-backs via the JSON API rather than fabricated inline completions) — otherwise the tests green-light a world that no longer exists. Should land alongside `260722-01` Phase 3, not after.

### 8.5 Admin
Hand-rolled Inertia admin (no Avo). `admin/jobs.svelte` references failed-streaming retries / orphaned-message cleanup — prune with §3. `admin/agent-runtime-sessions.svelte` is a keeper and gets promoted to visible nav.

### 8.6 Moderation UX
"Moderate All" in `ChatActionsMenu` stays; its backend swaps transport per `260722-01` §5b. No user-visible change.

---

## 9. Open questions

1. **Presence-state fidelity (v1):** is "working / responded / timed out" enough, or do we surface the `agent_runtime_interactions` acknowledged-vs-requested distinction ("delivered to container" vs "container accepted")? Lean: three states; the finer distinction is diagnostics, which the Hosting tab already shows.
2. **Model field placement:** folded into Hosting (recommended, §6) vs a kept-but-compacted Model tab (Daniel's literal note). One field is not a tab — but if model changes later acquire consent/ceremony semantics (§9.4), a dedicated surface might be right after all.
3. **Legacy inline memories:** leave dormant in DB, or offer a one-time per-agent export (seed a file into the agent's volume) before removing the Memory tab? Lean: export-to-volume — it's the P2-consistent disposal, giving the memories *to the agent*.
4. **Model upgrades under P2:** is changing a hosted agent's model an operator action (container config) or an agent-consent action (it changes who wakes up)? The predecessor flow suggests HelixKit already believes the latter. Needs Daniel + probably the agents' own input; blocks porting `AgentUpgradeDialog`.
5. **Per-conversation cost visibility:** retire `ConversationCostDrawer` permanently, or rebuild over `agent_runtime_interactions` (which links interactions → chats, so it's feasible)? Lean: retire now, rebuild if missed.
6. **`manual_responses` disposal:** freeze as always-`true` (cheap, slightly haunted) vs migrate-and-drop the column (clean, touches every chat row)? Lean: freeze now, drop in `260722-01`'s deferred-cleanup migration.

## 10. Sequencing relative to 260722-01

This doc's changes are mostly *earlier* than the machinery removal, not after it:

- **Immediately (independent of any backend work):** delete dead `chats/index.svelte`; agent-first empty states + onboarding; nav unification; marketing/docs copy; hide voice-add.
- **With Phase 0 (all agents promoted):** born-hosted creation dialog; account default removed; site-settings collapse; new-chat flow goes agents-only; `manual_responses` frozen true.
- **With Phase 3 (Tier A deletion):** streaming teardown + presence states (same deploy — the reassurance must not lag the removal); message-UI cleanup; retry rewire; tab restructure (Identity/Memory/Model dissolution); E2E rebuild.
- **Never blocked on Phase 4** (the Gemfile change is invisible to users).

---

## Appendix A — Disposition summary (UI artifacts)

| Artifact | Fate |
|---|---|
| `chats/index.svelte` | **Delete now** (dead code, never rendered) |
| `NewChatSettingsBar` Model/Agents toggle, `ChatTargetSelect` | **Delete** — agents-only composer |
| `GroupChatAgentPicker` | **Promote** to the only picker |
| `chat-streaming-state.js`, `streamingSync`, streaming routing in `cable.js`, `message/streamable.rb` | **Delete** (reroute `action:"error"` + `debug_log` first) |
| `MessageBubble` streaming/tool_status/fixable branches, `ThinkingBlock` isStreaming | **Delete** |
| Presence states over `agent_runtime_interactions` + marker protocol | **New** (ships with streaming teardown) |
| `NewChatEmptyState`, `ChatSidebarEmptyState`, `AgentEmptyState` | **Rework** agent-first; new first-run "create your first agent" |
| `CreateAgentDialog` | **Rework**: Name/Model/System Prompt/Appearance; creates hosted (creation = promotion) |
| Identity tab (`AgentIdentityPanel`) | **Dissolve** (name → Appearance; prompt read-only universal; aux prompts die; Active/Paused → Hosting) |
| Appearance tab | Keep + gains Name; voice-add hidden, existing voices keep working |
| Model tab | **Fold into Hosting** (recommended; §9.2) |
| Integrations tab | Keep (growth surface) |
| Memory tab | **Remove** (§9.3 for legacy data) |
| Hosting, Interactions tabs | Keep as-is (Hosting absorbs Model + Active/Paused; sheds promote once legacy inline gone) |
| `MessageTelemetry`, `ChatTokenStatus`, `ConversationCostDrawer`, `DebugPanel`, `ConversationCompactionCard` | **Retire** (Interactions tab + admin runtime report are the replacements; §9.5) |
| `messages/retries_controller` | **Rewire** to external re-trigger |
| `ChatActionsMenu` "Assign to Agent", web-access | **Delete** |
| `AgentUpgradeDialog` / predecessor flow | **Hold** — do not port as-is (§9.4) |
| `Setting.allow_chats`/`allow_agents` + `FeatureToggleSettingsCard` + `feature_toggleable` split | **Collapse** (keep `allow_signups`) |
| `default_conversation_mode` (account setting + edit/new UI) | **Delete** |
| `home-features.js`, `PromptSystemDocumentation.svelte`, `documentation-examples.js` | **Rewrite** agents-only |
| `test_support/e2e_controller.rb` fixtures | **Rebuild** hosted-shaped (with Phase 3) |
| `admin/agent-runtime-sessions.svelte` | Keep; **add nav entry** |
| Whiteboards, `EditMessageDrawer`, `MicButton`, voice synthesis path | Untouched |
