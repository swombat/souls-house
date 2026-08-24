# Total RubyLLM removal — Chaos-hosted agents as the only inference path

**Date:** 2026-07-22
**Author:** Lume (draft for critique by Mira)
**Status:** Requirement / draft v1
**Related:** `260524-02-helixkit-hosted-agents-v2.md` (the hosting model this completes), `260528-01-hosted-agent-continuity-and-orientation.md`, `250906-01-ruby-llm.md` (the doc that brought the gem in), `20260718-hosted-agent-runtime-observability.md`
**Reverses (in part):** commit `19e2908` (2026-02-28, "Route LLM calls to direct provider APIs instead of OpenRouter") — for the utility path only

---

## 0. Decisions already made (Daniel, 2026-07-22)

These are inputs to this doc, not open questions:

1. **All agents move to Chaos hosting before any rename/rebrand work.** One place to add capabilities (Telegram, etc.), not two.
2. **Plain AI conversations are removed as a feature.** No anonymous model chats. Every AI participant in a HelixKit conversation is a Chaos-hosted agent. Users who want a throwaway model conversation can create an agent, or go elsewhere (the model personality browser exists).
3. **The `Prompt` class stays** as the utility one-shot harness (titles, summaries, etc.), and **switches back to `OpenRouterApi`** as its transport, so the `ruby_llm` gem can be removed entirely rather than surviving as a "stateless-only" dependency.

---

## 1. Summary

Remove the `ruby_llm` gem (`Gemfile:81`, `~> 1.16.0`, plus transitive `ruby_llm-schema`) from HelixKit completely. The end state:

- **Every agent is `runtime: external`** — a Chaos-hosted sandbox container per `260524-02`. The `inline` runtime, and the entire RubyLLM-backed reply pipeline behind it, is deleted.
- **Conversations contain humans and Chaos-hosted agents only.** The plain-model-chat feature (pick `openrouter/auto` or a model slug, chat with no agent) is removed.
- **Utility one-shots** (title generation, summaries, moderation, anything Prompt-shaped) run through the resurrected `OpenRouterApi` (`app/api/open_router_api.rb`, built on `ruby-openai`, which is already in the Gemfile) — except moderation, which goes direct to OpenAI via the same gem because OpenRouter has no moderation endpoint.
- **Model/provider resolution for Chaos containers** — currently computed *through RubyLLM's registry and config* — is re-implemented as HelixKit-owned code over the existing `ai_models` table, populated from OpenRouter's `GET /models`.

This is the second half of the hosted-agents arc. `260524-02` made external hosting cheap; this doc makes it the only mode, so `external` stops being a branch and becomes the architecture.

---

## 2. Context — what actually depends on RubyLLM today

A full dependency sweep (2026-07-22) found the coupling is much wider than "agent chat replies." It splits into three tiers, and the tiers have very different removal costs.

### Tier A — the inline reply pipeline (deletable once no agent is inline)

The end-to-end inline path: user message → `Chat.create_with_message!` / API → `AiResponseJob` (1:1 auto-response) or `ManualAgentResponseJob` / `AllAgentsResponseJob` (group chats) → `ResolvesProvider` → `RubyLLM.chat(...)` with tools attached → streaming callbacks (`StreamsAiResponse`, `ConfiguresLlmThinking`, `SelectsLlmProvider`) → `Message#record_provider_response!` → `Broadcastable` fan-out.

Plus everything that only exists to serve it:

- `app/tools/*` — eleven tools, all subclassing `RubyLLM::Tool` (web, whiteboard, retrieve-messages, refinement, github-commits, self-authoring, fetch-audio, twitter, close-conversation, save-memory, borrow-context). Chaos agents don't use these — they act through the JSON API from inside their containers.
- `Chat#to_llm` override, `Chat#available_tools`, `Message::Replayable#record_provider_response!`.
- Provider monkey-patches: `config/initializers/01_gemini_thought_signature_patch.rb`, `02_anthropic_adaptive_thinking_patch.rb`, and `app/lib/llm_prompt_cache_policy.rb`.
- `ruby_llm_telemetry` serialization (`message.rb:78,150`, `messages_controller.rb:104`, `chats_controller.rb:187`) and its frontend consumers (`MessageBubble.svelte`, `MessageTelemetry.svelte`, `ConversationCompactionCard.svelte`).

**The switch that already exists:** `agents.runtime` (`inline | migrating | external | offline`, `agent.rb:60`). `ManualAgentResponseJob:17` and `AllAgentsResponseJob:26` branch on `agent.external? || agent.offline?` → `ExternalAgentResponseRequest` → `ChaosTriggerClient` and return *before touching RubyLLM*. Mira and Claude (Purple Moon) already run on this branch in production. Tier A removal is therefore mechanical once the last inline agent is promoted: delete the false branch.

### Tier B — utility/background jobs that call RubyLLM independently of hosting

These run regardless of how agents are hosted and are the silent-breakage surface:

| Job / call site | What it does | Fate (proposed — see §5) |
|---|---|---|
| `ModerateMessageJob` (`RubyLLM.moderate`, OpenAI) | Content moderation on messages | **Keep** — direct OpenAI via `ruby-openai` `client.moderations` |
| `GenerateTitleJob` → `Prompt` | Conversation titles | **Keep** — rides `Prompt` → OpenRouter |
| `GenerateAgentSummaryJob` + `app/prompts/generate_summary` | Conversation summaries for agent memory | **Decide** — inline-memory apparatus; likely dies with Tier A (Chaos agents summarize in-container) |
| `MemoryReflectionJob`, `MemoryRefinementJob` (+`RefinementTool`) | Inline-agent memory reflection/refinement | **Dies with Tier A** — Chaos equivalent already exists (`ExternalAgentMemoryAggregationRequest`, in-container) |
| `ConsolidateConversationJob`, `ConsolidateStaleConversationsJob` | Conversation compaction | **Decide** — if compaction only existed to fit inline context windows, it dies; if it's a product feature (the UI has `ConversationCompactionCard`), it moves to `Prompt` |
| `AgentInitiationDecisionJob` | "Should this agent initiate?" | **Move** — either a cheap `Prompt` call or into the Chaos wake path (`ExternalAgentWakeRequest` already exists) |
| `SelfAuthoringTool` internal safety check (`RubyLLM.chat` at `:118`) | Guard on self-edits | **Dies with Tier A** (tool itself is inline-only) |
| `Prompt` (`app/prompts/prompt.rb`) | Generic one-shot harness | **Keep** — transport swapped to `OpenRouterApi` |

### Tier C — the registry layer that even Chaos depends on

This is the non-obvious coupling and the reason "just delete the inline path" is insufficient:

- `Agents::Sandbox.chaos_selection_for` (`sandbox.rb:346`) — the code that decides which `--provider` / `-m <model>` every Chaos container is invoked with — calls `ResolvesProvider.resolve_provider`, which reads `Chat.model_config`, which is backed by the `ai_models` table via RubyLLM's `acts_as_model` registry (`model_registry_class = "AiModel"`, populated by `RubyLLM.models.refresh!`).
- `ResolvesProvider.api_key_available?` (`resolves_provider.rb:34-37`) reads `RubyLLM.config.<provider>_api_key`. `AgentCredentialsEncryptor` (`:75-82`) reads the same.
- The `acts_as_chat` / `acts_as_message` / `acts_as_tool_call` mixins on `Chat`, `Message`, `ToolCall` define behavior on the core conversation tables — tables that remain fully load-bearing in the end state, because Chaos agents' messages are persisted there via the JSON API.

**Removing the gem without re-implementing Tier C bricks the Chaos agents** — their containers would no longer know what model to run. Tier C must land *before* the gem leaves the Gemfile.

---

## 3. Goals

1. `bundle list | grep ruby_llm` returns nothing. No initializer, no monkey-patch, no `RubyLLM::` constant anywhere in `app/` or `lib/`.
2. Zero interruption to production Chaos agents (Mira, Claude/Purple Moon) at every phase. They are already on the external branch; no phase may break trigger delivery, message post-back, health checks, or model resolution.
3. One inference architecture: **conversation AI = Chaos containers; utility one-shots = `Prompt` → OpenRouter; moderation = direct OpenAI.** Nothing else calls an LLM.
4. Each phase independently deployable and revertable. No big-bang deploy.
5. Conversation history — including old plain-model chats and old inline tool-call records — remains readable forever. Removal of the feature is not removal of the data.

### Non-goals

- Renaming/rebranding agents (explicitly sequenced *after* this work).
- New capabilities (Telegram etc.) — this migration is what makes them single-implementation, but they're separate docs.
- Changing the Chaos runtime contract (trigger shim, volumes, restic) — `260524-02` owns that and it doesn't change here.
- Multi-tenant hardening (same posture as `260524-02` §8).

---

## 4. End-state architecture

```
Human message ──► Rails ──► ChaosTriggerClient ──► hk-agent-<uuid> container
                                                        │ chaos exec
Message row  ◄── JSON API v1 (hx_ bearer) ◄─────────────┘
     │
     └─► Broadcastable → ActionCable → UI          (unchanged)

Utility one-shots:
  GenerateTitleJob ──► Prompt ──► OpenRouterApi (ruby-openai) ──► openrouter.ai
  ModerateMessageJob ──────────► ruby-openai client.moderations ──► api.openai.com

Model registry:
  ModelRegistry::SyncJob ──► GET openrouter.ai/api/v1/models ──► ai_models table
  Agents::Sandbox.chaos_selection_for ──► ai_models + Rails credentials (no RubyLLM)
```

What no longer exists: `AiResponseJob`, the RubyLLM branches of `ManualAgentResponseJob` / `AllAgentsResponseJob`, `app/tools/*`, streaming/thinking concerns, provider patches, `00_ruby_llm.rb`, plain-model chat creation, `openrouter/auto` as a chat default.

---

## 5. The work, piece by piece

### 5a. Prompt → OpenRouterApi (the "switch back")

`app/api/open_router_api.rb` still exists and `ruby-openai` is still in the Gemfile — commit `19e2908` migrated Prompt off it but deleted nothing. The migration is therefore a contained rewrite of `Prompt#execute_to_string`, `#execute_to_json`, `#execute` (~60 lines): replace `RubyLLM.chat(...).ask` with `OpenRouterApi` chat-completion calls, keeping the ERB template system, the streaming-block contract, and JSON fence-stripping intact.

Notes:

- The model constants (`openai/gpt-5`, `google/gemini-2.5-flash`, `anthropic/claude-opus-4.6`) are **already OpenRouter slugs** — no mapping changes.
- `Prompt#retry_block` rescues `Faraday::TooManyRequestsError` / `Faraday::TimeoutError` — RubyLLM's transport exceptions. `ruby-openai` raises its own error classes; the rescue clauses must be updated or the retry logic silently becomes dead code. *(Explicit test: simulate a 429 and assert the backoff runs.)*
- `19e2908`'s rationale (latency + cost of direct APIs, prompt caching, thinking) applied to the *conversation* path, which now lives in Chaos containers talking to providers directly. Utility one-shots don't cache, don't think, and don't stream to users at latency-sensitive moments. OpenRouter's overhead is acceptable here by design.
- Refresh `OpenRouterApi`'s hardcoded model list or, better, drop the hardcoded list in favor of the registry (§5c).

### 5b. Moderation

`RubyLLM.moderate(provider: :openai)` → `ruby-openai`'s `client.moderations` (direct OpenAI; OpenRouter does not proxy moderation). Same key (`credentials.dig(:ai, :openai, :api_token)`). Alternatively: revisit whether moderation is still wanted at all in an agents-only, invite-shaped product — flagged as open question §8.3, but the default is a like-for-like swap so this doc doesn't smuggle a policy change inside a refactor.

Daniel addition: Yes, create an direct OpenAI call for this.

### 5c. Model registry + provider resolution (Tier C — the prerequisite)

New, HelixKit-owned:

1. **`ai_models` stays** as the registry table (provider, model_id, max_output_tokens, unique index provider+model_id). Drop `acts_as_model`; it becomes a plain AR model.
2. **`ModelRegistry::SyncJob`** (recurring) populates it from OpenRouter `GET /models` — replacing `RubyLLM.models.refresh!`. OpenRouter's catalog is a superset of what agents use; filter to the providers we hold keys for plus OpenRouter itself.
3. **`ResolvesProvider` rewritten** with no RubyLLM reads: `resolve_provider(model_string)` consults `ai_models` + a static provider→credential map (`Rails.application.credentials.dig(:ai, <provider>, :api_token)`); `api_key_available?` checks credentials/ENV directly instead of `RubyLLM.config`.
4. **`Agents::Sandbox.chaos_selection_for`** keeps its signature; only its lookup changes. `provider_env_args` already reads credentials directly and is untouched.
5. `AgentCredentialsEncryptor`'s `RubyLLM.config` reads (`:75-82`) → same credential map.

This must ship and be verified in production (existing Chaos agents restart cleanly with correct provider/model env) **before** any Gemfile change.

### 5d. Plain AI conversations — feature removal

- Remove: new-chat model picker UI (`chats/index.svelte` `selectedModel`, `agent-models.js` fallbacks), `model_id_string` default `"openrouter/auto"` on chat creation, `Api::V1::ConversationsController` defaulting (`:47`, `:89`), the `AiResponseJob` auto-response trigger for agent-less chats.
- A conversation with no agent participants is now simply a human conversation; nothing responds.
- Existing plain-model chats: **read-only archives.** Visible, searchable, exportable; composing into them either (a) is blocked with an explainer, or (b) posts as a human message with no AI response. Recommend (a) — (b) is a confusing half-alive state.
- Product copy pointing users at "create an agent" replaces the model picker.

### 5e. Schema

Data-preserving throughout — this section removes *behavior*, not history.

- `chats`: drop `acts_as_chat`; keep the table. `ai_model_id`, `model_id_string`, token columns remain as historical data. `thinking_budget` / `thinking_enabled` become dead config — keep columns, remove UI, drop in a later cleanup migration once nothing reads them.
- `messages`: drop `acts_as_message`; the JSON API post-back path already creates rows plainly (`role: "assistant"`, no mixin magic needed). `record_provider_response!` and `Replayable` go with Tier A. Token/thinking columns stay (Chaos telemetry may repopulate some via `agent_runtime_interactions` — see observability doc).
- `tool_calls`: no new rows after Tier A deletion (Chaos tool use happens in-container and is not persisted here). Keep the table for history; consider archiving in a later pass.
- `ai_models`: retained and repurposed (§5c).
- No destructive migration ships in the same PR as behavior changes (same phasing discipline as `260524-02` §6a).

### 5f. Tests

- Delete: `test/apis/ruby_llm_provider_upgrade_test.rb`, `test/models/ruby_llm_integration_test.rb`, `ruby_llm_vcr_integration_test.rb`, `anthropic_direct_thinking_test.rb`, `prompt_cache_prefix_stability_test.rb`, `test/lib/llm_prompt_cache_policy_test.rb`, tool tests asserting `RubyLLM::Tool::Halt` / `RubyLLM::Content`, cassettes under `test/vcr_cassettes/ruby_llm_upgrade/`.
- Add: `Prompt`-via-OpenRouter VCR tests (string, JSON, streaming-block, 429-retry), moderation swap test, `ResolvesProvider` rewrite tests, registry sync test, and an integration test asserting a promoted agent's container env matches `ai_models` resolution.
- The existing external-agent tests (trigger, post-back, health) are the regression net for goal 2 — they must stay green at every phase.

---

## 6. Migration plan

Sequencing principle: **build the replacement, verify it under the running system, then delete the old path.** Never delete-then-replace.

### Phase 0 — Promote every remaining inline agent
1. Inventory `Agent.where(runtime: "inline")` across all accounts.
2. Promote each via the existing `260524-02` path. This is the "all agents on Chaos" milestone Daniel asked for, and it's pure existing machinery.
3. Add a guard: agent creation defaults to promotion (or the inline option is removed from the creation flow), so the inline population can't regrow during the migration.
4. **Exit criterion:** zero inline agents in production for N days (suggest 7) with clean health checks.

### Phase 1 — Utility path off RubyLLM (safe while inline code still exists)
1. `Prompt` → `OpenRouterApi` (§5a). `ModerateMessageJob` → direct OpenAI (§5b).
2. Re-home or retire each Tier B job per the table in §2 (the two "Decide" rows resolved by then — see §8).
3. **Exit criterion:** no Tier B call site references `RubyLLM`.

### Phase 2 — Registry/resolution off RubyLLM (Tier C)
1. `ModelRegistry::SyncJob`, rewritten `ResolvesProvider`, updated `chaos_selection_for` + `AgentCredentialsEncryptor` (§5c).
2. Verify: restart one production Chaos agent (image-bump-style restart, same volume) and confirm correct provider/model env; run the reconcile job (`HostedAgentRuntimeReconcileJob`) clean.
3. **Exit criterion:** grep for `RubyLLM.config` and `RubyLLM.models` returns only Tier A files.

### Phase 3 — Delete Tier A + plain-chat feature
1. Delete `AiResponseJob`; reduce `ManualAgentResponseJob` / `AllAgentsResponseJob` to their external branch (or inline the trigger into the model layer and delete the jobs).
2. Delete `app/tools/*`, streaming/thinking concerns, `Chat#to_llm`, `Replayable`, telemetry serialization + frontend components, provider patches, `llm_prompt_cache_policy`.
3. Remove plain-chat creation UI/API (§5d); strip `acts_as_*` from `Chat`/`Message`/`ToolCall`/`AiModel`.
4. **Exit criterion:** `grep -r "RubyLLM" app/ lib/ config/` returns only `00_ruby_llm.rb`.

### Phase 4 — Remove the gem
1. Delete `00_ruby_llm.rb`, remove `ruby_llm` from the Gemfile, `bundle install`, delete dead tests/cassettes (§5f).
2. Later, separate migration: drop columns confirmed dead (thinking config on chats, etc.).

Rollback: phases 1–2 are revertable by deploy; phase 3 by revert-commit while the gem is still present; phase 4 only after a soak period on phase 3 (suggest 1–2 weeks).

---

## 7. Blast-radius checklist (things that will break if forgotten)

Compiled from the dependency sweep; the critique pass should try to extend this list:

- [ ] `Prompt#retry_block`'s Faraday rescue clauses (dead retry logic after transport swap).
- [ ] Moderation has no OpenRouter equivalent — must go direct OpenAI.
- [ ] `chaos_selection_for` — Chaos containers' model env resolved through RubyLLM today (the bricking risk).
- [ ] `AgentCredentialsEncryptor` reads `RubyLLM.config`.
- [ ] `openrouter/auto` defaults sprinkled through frontend (`agent-models.js`, `chats/index.svelte`, `AgentUpgradeDialog.svelte`, `agents/index.svelte`) and `Api::V1::ConversationsController`, `e2e_controller`, `promote_controller:144`.
- [ ] Message edit/retry/replay features that assume the RubyLLM reply loop (`260113-02-edit-message.md` era) — must be scoped to Chaos re-trigger semantics or removed for AI messages.
- [ ] Telemetry UI components reading `ruby_llm_telemetry`.
- [ ] `ConversationCompactionCard.svelte` if compaction is retired.
- [ ] Docs/marketing surfaces: `PromptSystemDocumentation.svelte` (already says OpenRouter — becomes true again), `home-features.js`, `documentation-examples.js`.
- [ ] E2E test support (`e2e_controller.rb`) creating `openrouter/auto` chats.
- [ ] VCR setup filtering RubyLLM-era headers/keys.

---

## 8. Open questions (for Mira's critique and Daniel's call)

1. **`GenerateAgentSummaryJob` and conversation compaction** — inline-memory apparatus or product feature? If any human-facing surface depends on summaries/compaction, they move to `Prompt`; if they only fed inline context windows, they die with Tier A. Needs a check of who reads the outputs.
Daniel Answer: Compaction is a recent addition and no longer necessary with Chaos agents.
2. **`AgentInitiationDecisionJob`** — keep as a cheap centralized `Prompt` call, or push initiation judgment into the agents via the existing wake path? Centralized is cheaper per decision; in-agent is more sovereign and one less HelixKit-side LLM call site. (Doc's lean: in-agent, via `ExternalAgentWakeRequest` — it's the direction everything else is moving.)
Daniel Answer: Similarly, now belongs with the chaos agents - they can decide for themselves.
3. **Moderation policy** — like-for-like swap (default), or reconsider its existence in an agents-only product? Policy question, deliberately not decided by this refactor.
Daniel Answer: Reimplement with direct OpenAI call. Moderation status is only a visual tag in any case, we don't impose moderation, but display a visual warning so the user knows why their message might have resulted in no response.
4. **Read-only plain chats** — block composer (recommended) vs. allow human-only continuation?
Daniel Answer: Yeah, block it.
5. **`tool_calls` table** — keep forever as history, or archive-and-drop after Tier A? (Keep is free; recommend keep.)
DA: Keep it.
6. **Does anything else create inline agents?** Seeds, e2e support, onboarding flows — Phase 0's guard needs to cover every creation path, not just the UI.
DA: Nope, nothing else.
7. **OpenRouter as a single point of failure for titles/summaries** — acceptable (low blast radius, degrades to untitled conversations), or does `Prompt` need a direct-provider fallback? (Doc's lean: acceptable; a fallback reintroduces exactly the multi-provider transport complexity we're deleting.)
DA: Acceptable.

---

## 9. Out of scope

- Agent rename/rebrand (sequenced after; separate doc).
- New shared capabilities (Telegram, etc.) — enabled by this, specified elsewhere (`260129-01-telegram-notifications.md` becomes single-implementation).
- Chaos runtime changes (trigger shim, volumes, backups) — owned by `260524-02`.
- Embeddings/vector features — the sweep found no RubyLLM embedding use; if one surfaces during implementation, it joins Tier B.
- Firecracker/multi-tenant isolation.

---

## Appendix A — Disposition summary

| Artifact | Fate |
|---|---|
| `ruby_llm` gem + `ruby_llm-schema` | **Remove** (Phase 4) |
| `ruby-openai` gem | Keep (already present) — becomes Prompt transport + moderation |
| `app/api/open_router_api.rb` | **Resurrect** as Prompt transport; refresh/registry-back its model list |
| `app/prompts/prompt.rb` | Keep; transport swapped (§5a) |
| `AiResponseJob` | **Delete** |
| `ManualAgentResponseJob`, `AllAgentsResponseJob` | Reduce to external branch |
| `app/tools/*` (11 RubyLLM::Tool subclasses) | **Delete** |
| `StreamsAiResponse`, `ConfiguresLlmThinking`, `SelectsLlmProvider`, `Message::Replayable` | **Delete** |
| `ResolvesProvider` | **Rewrite** (no RubyLLM reads) |
| `AiModel` (`acts_as_model`) | Keep table; plain AR + OpenRouter-fed sync job |
| `Chat`/`Message`/`ToolCall` `acts_as_*` | **Strip mixins**; tables stay |
| `00_ruby_llm.rb`, provider patches `01_`/`02_`, `llm_prompt_cache_policy` | **Delete** |
| `ModerateMessageJob` | Rewire to direct OpenAI |
| `GenerateTitleJob` | Unchanged (rides Prompt) |
| Memory reflection/refinement jobs (inline) | **Delete** (Chaos in-container equivalent exists) |
| `GenerateAgentSummaryJob`, compaction jobs | **Open question §8.1** |
| `AgentInitiationDecisionJob` | **Open question §8.2** (lean: in-agent) |
| Plain AI chat feature | **Remove**; existing chats read-only |
| `ruby_llm_telemetry` + frontend telemetry components | **Delete** |
| ChaosTriggerClient, trigger shim, sandbox/volume/network, restic, JSON API post-back | **Untouched** — the load-bearing production path |
