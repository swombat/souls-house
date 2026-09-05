# RubyLLM retirement: implementation and rollout

Implemented in `souls-house-1`, on local `master`. Other instances and production
have not been changed. This document supersedes the earlier WIP checkpoint.

## What changes

- Removes `ruby_llm`, `ruby_llm-schema`, their now-unused retry dependency, the
  three provider initializers, Active Record macros, provider response/replay
  conversion, inline context assembly and streaming concerns.
- Replaces persistence macros with ordinary Rails associations. Conversations,
  model references, ordered messages, signed thinking, token usage, tool calls,
  tool results and attachment bytes remain readable. Forks preserve model and
  reasoning metadata and relink copied tool results to copied tool calls.
- Removes all nine Rails tool wrappers, dynamic discovery/validation, tool
  settings, refinement/initiation controls and hallucinated-tool recovery.
  Whiteboards, memories, integrations and the house APIs remain.
- Removes the promotion wizard and migration sweeper. New births provision
  through `ProvisionAgentJob`. Existing promoted residents do not need a birth
  timestamp; none is fabricated.
- Model-upgrade predecessor records are historical, deprecated snapshots, not
  runnable cross-version residents. The UI explains this; no harness or
  credentials are cloned.
- Keeps old serialized job names as no-op shells for queue drainage.
  `PromoteAgentJob` remains a compatibility alias that provisions only an
  already-provisioning resident. Legacy message-retry requests return a retired
  response without inference; the UI no longer offers them.
- Removes obsolete framework/tool tests and their cassettes; replaces execution
  expectations with history-preservation, no-op, admission and utility tests.
  Existing non-agent HTTP integration tests remain.
- Fixes the onboarding member-route lookup discovered by the new-birth browser
  journey. Creation now reaches the preparation page instead of a 404.

Historical schema is intentionally retained: enabled-tool names, prompt fields,
summaries, replay payloads and telemetry are data, not permission to execute.
Historical `ruby_llm_telemetry` JSON keys remain compatible with existing views.
Old vendor documentation is explicitly labelled historical.

## Availability contract

| Runtime | Harness/storage | Conversation selection/dispatch |
| --- | --- | --- |
| `external`, `offline` | Supported | Available when active, including paused |
| `provisioning` | Supported | Unavailable until ready |
| `deprecated`, legacy `inline`/`migrating` | Unsupported | Unavailable |
| Unknown | Unsupported | Unavailable |

Legacy values fail closed **before** the explicit data transition. Old
participants remain visible in history, labelled unavailable; they are not
removed from conversations. Agent-scoped keys cannot authenticate unsupported
runtimes; owner keys still work. Announce cannot reactivate a deprecated agent.
Selectors and direct web/API admissions reject unavailable residents. Stale
manual jobs emit transient `agent_skipped` notices, not fabricated assistant
messages, and mixed-agent chains advance. Sandbox and Telegram dispatch are
guarded too.

The additive migration introduces `deprecated_at` and `deprecation_reason` and
changes the default runtime to `deprecated`. It does **not** transition existing
rows. The explicit transition preserves identity, memory, history, active/paused
intent and actual birth provenance. Development test-agent setup also preserves,
rather than replaces, an existing deprecated resident.

## Utility inference

`UtilityInference` uses the existing `ruby-openai` client, not a new provider
framework:

| Use | Provider/model | Credential policy |
| --- | --- | --- |
| Titles | OpenRouter / `google/gemini-2.5-flash` | Account key; system fallback only when permitted |
| Moderation | OpenAI / `omni-moderation-latest` | Site key |
| Safeguard classifier | OpenRouter / `openai/gpt-5.6-luna` | Site key |

Missing title credentials skip inference. Empty or invalid moderation results
never set `moderated_at`; existing thresholds remain unchanged. Classifier
prompt, verdict parsing and fail-open failure accounting are preserved, without
logging raw provider errors in classifier notifications.

Calls have a 20-second timeout and 32,000-character input limit. Title input is
additionally limited to 12 messages of 240 characters each. Outputs are bounded
to 100/200 tokens for titles/classification. Oversized classification fails open;
it is not silently truncated. The client has no retry middleware. Moderation
alone retries transient transport failures, at most three attempts.

**Deferred deliberately:** Chaos selection still checks system credentials when
no account is supplied, while its runtime environment uses account provider
keys. Removing RubyLLM replaces the source of system-key lookup; it does not
silently change that routing policy.

## Operator rollout and rollback gates

These are instructions for a separately approved deployment, not actions already
performed.

1. Record the tested release commit and take the normal verified backup.
   Inventory production legacy/migrating/provisioning states and contradictory
   harness metadata. Resolve in-flight migrations/provisioning explicitly;
   do not wake, copy or replace a resident as a side effect.
2. Deploy the additive migration and this compatible binary. The extraction
   binary itself handles legacy rows and old queued job names; a partially
   removed intermediate binary is unnecessary. Restart **every web, job and
   scheduler process** and verify that no old inline executor remains before
   changing runtime data. Treat this tested commit as the rollback floor.
3. Obtain a fresh read-only inventory; it contains flags, not secret values:

   ```sh
   bin/rails agents:deprecation_inventory
   ```

4. After explicit operator approval, submit the reviewed numeric database IDs:

   ```sh
   CONFIRM=deprecate-inline REVIEWED_IDS=123,456 bin/rails agents:deprecate_inline
   ```

   The transaction locks the candidate rows and requires the complete inline
   candidate set. It rejects unresolved migrating rows, missing IDs, supported
   runtimes and candidate harness metadata. It stamps runtime/reason/time and
   clears trigger tokens. Repeating the same reviewed list is safe; an empty
   list never means “all agents.”
5. Verify retired scoped credentials, announce and dispatch fail closed;
   current harness residents, owner credentials, history, downloads and utility
   inference must continue to work. Do not invoke test wakes against real
   residents merely to validate deployment.
6. Keep historical columns and no-op queue shells in this release. Once this
   release is installed, roll back only to a compatible tested binary—not an
   old inline executor. Rollback must never reactivate retired agents or restore
   cleared trigger tokens. Remove queue shells only in a later release after
   explicitly verifying old queues are drained.

Only instance-one development/test schema migrations have been run here.

## Verification

- Full Rails suite: **2,066 tests, 10,434 assertions, zero failures/errors**.
- Additional final provisioning/Telegram/announce/admission hardening:
  **28 tests, 145 assertions, zero failures/errors**.
- Focused extraction/history/web admission/upload tests:
  **168 tests, 730 assertions, zero failures/errors**.
- Final model/predecessor checks: **73 tests, 222 assertions, zero
  failures/errors**, including unavailable snapshots without copied credentials
  or fabricated birth provenance.
- Frontend unit suite: **19 files, 71 tests passed**, including unavailable
  participant controls and paused/offline harness availability.
- Browser suite: **18 journeys passed**, including deprecated-resident screens,
  new-birth onboarding, account administration, attachments and multi-window
  history synchronization.
- Eager loading (`zeitwerk:check`) and `git diff --check` pass.
- Stock RuboCop is blocked by the pinned parser's unsupported Ruby 4 target.
  **101 changed Ruby files pass** with an instance-local temporary Ruby 3.4
  parser target; repository lint rules are not changed.
- Changed hand-written frontend sources, new unit tests and modified E2E tests
  pass Prettier. Repository-wide formatting still flags six untouched files
  (`application.css`, `AgentAppearancePanel.svelte`, `logging.js`, `use-sync.js`,
  `agents/new.svelte`, `home.svelte`) and generated `routes/index.js`.

No production transition, deployment, push or cross-instance integration has
been performed.
