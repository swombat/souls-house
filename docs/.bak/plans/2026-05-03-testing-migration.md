# Testing Migration Plan

Date: 2026-05-03

## Goal

Move Helix Kit from a broad but noisy frontend-heavy test setup to a refactor-grade test strategy:

1. Thorough Rails tests as the everyday safety net.
2. Focused Vitest tests only for stable frontend behavior and extracted logic.
3. Deterministic Playwright E2E tests for critical browser flows, especially chat and UI sync.

The end state should let us refactor the Svelte side with confidence instead of fighting brittle tests that duplicate implementation details.

## Current Findings

### Rails

The Rails suite is substantial and mostly aligned with the new strategy.

Current observed state:

- 157 Rails test files.
- 1,834 Rails test methods.
- `bin/rails test` currently fails with 1 assertion failure and 4 errors.
- The 4 errors are caused by Vite test asset compilation failing, not by the individual Rails controller/integration behavior under test.
- The frontend build error is caused by `app/frontend/pages/chats/index.svelte` using `Select.Value`, while `app/frontend/lib/components/shadcn/select/index.js` does not export `Value`.
- The assertion failure is in `test/models/agent_test.rb`, around `Agent#as_json` memory stats.

There is also a policy gap:

- Several Ruby tests currently use `stub`, `Minitest::Mock`, or fake objects.
- Some API tests print diagnostics and have missing assertions.

### Vitest

Vitest is currently mostly the kind of suite we want to move away from.

Current observed state:

- 21 Vitest files.
- 189 Vitest test cases.
- `yarn test:unit --run` currently fails with 26 failures.
- Most failures are caused by mocked Inertia shape drift, exact text/date expectations, missing mock props, or component implementation changes.

Most current Vitest tests are low-value page/component render tests. They do not provide good refactor safety.

### Playwright

Playwright exists, but in the wrong shape.

Current observed state:

- 8 Playwright Component Test files.
- 77 configured Playwright CT cases.
- 1 E2E-style spec exists at `test/e2e/chat_feature.spec.js`.
- There is no E2E Playwright config or package script that includes `test/e2e/chat_feature.spec.js`.
- `yarn test` currently runs the Playwright Component Test harness, not the desired E2E suite.

The configured Playwright tests mostly check component rendering, text, icons, placeholders, and mocked props. They are not the browser contract suite we need.

## Migration Steps

### 1. Stabilize Rails Baseline

Fix the current failures so Rails gives us a trustworthy green baseline.

Tasks:

- Fix the frontend build issue around `Select.Value` in the chats index page.
- Re-run the Rails suite and confirm the Vite manifest is generated in test mode.
- Fix or update the `Agent#as_json` memory stats test/implementation after checking which behavior is now intended.
- Re-run `bin/rails test` until green.

Success criteria:

- `bin/rails test` passes.
- Asset compilation failures no longer cascade into unrelated Rails tests.
- Any remaining warnings are documented separately and do not hide failing tests.

### 2. Review Ruby Mocks Explicitly

Audit Ruby tests that use mocks, stubs, or fake collaborators.

Tasks:

- Find every use of `Minitest::Mock`, `.stub`, `stub_any_instance`, and custom fake API objects.
- Convert to VCR or real integration tests where straightforward.
- For each mock that appears necessary, document:
  - The file and test.
  - What is being mocked.
  - Why VCR or a real integration path is not suitable.
  - What behavior the test still protects.
- Ask Daniel for explicit confirmation before keeping each mock-based case.

Initial areas likely needing review:

- LLM job tests that stub `RubyLLM.chat`.
- Telegram/HTTP notification tests that stub `Net::HTTP`.
- Backup and credential/environment tests.
- GitHub integration tests using HTTP mocks.
- Speech/transcription tests using service stubs.

Success criteria:

- Mock usage is either removed or explicitly approved.
- Approved mocks have written justification.
- VCR-backed tests are preferred whenever the external interaction is HTTP-like and recordable.

### 3. Retire Noisy Vitest Tests

Stop maintaining Vitest tests that do not fit the new strategy.

Tasks:

- Classify existing Vitest files into:
  - Delete/quarantine.
  - Rewrite into useful behavior tests.
  - Keep temporarily until covered elsewhere.
- Avoid fixing current failing page/component tests unless they protect behavior that should remain covered by Vitest.
- Remove tests that assert:
  - Tailwind classes.
  - DOM wrapper structure.
  - Exact marketing/copy text.
  - Placeholder text.
  - Mocked Inertia behavior that does not exercise real app behavior.

Likely delete/quarantine candidates:

- Layout render tests.
- Auth/page render inventory tests.
- Most form tests that only check fields and submit buttons.
- Account/admin page tests that mirror current DOM structure.

Success criteria:

- `yarn test:unit` contains only tests with a clear behavioral purpose.
- The remaining Vitest suite is small, fast, and stable across reasonable Svelte refactors.

### 4. Sub-Agent Svelte Review

Before refactoring Svelte, have a sub-agent review the Svelte views and identify useful frontend unit tests that should exist first.

Purpose:

- Find behavior currently buried inside large Svelte files.
- Identify testable seams worth extracting.
- Avoid deleting all frontend unit coverage without replacing the genuinely useful parts.

Review scope:

- `app/frontend/pages/chats/show.svelte`
- `app/frontend/pages/chats/index.svelte`
- `app/frontend/pages/chats/ChatList.svelte`
- Chat components under `app/frontend/lib/components/chat`
- Agent selection/assignment UI.
- Message composer behavior.
- Thinking and streaming display behavior.
- Sync-related frontend code.

Expected output:

- A short list of frontend behaviors worth testing before refactor.
- Suggested extraction seams, preferably plain JavaScript modules.
- A list of tests that should be written now versus deferred until after structural cleanup.

Likely candidates:

- Message visibility filtering.
- Streaming message patch/merge behavior.
- Thinking display state.
- Enter versus Shift+Enter message composer behavior.
- Token warning level calculation.
- Message pagination state transitions.
- Sync debounce/reload behavior if extractable.
- Agent picker selection rules.

Success criteria:

- We have a targeted pre-refactor frontend test list.
- The list avoids broad component snapshot/render tests.
- Any new unit tests protect stable behavior, not temporary implementation.

### 5. Add Focused Vitest Tests

Write only the useful frontend unit tests identified in the Svelte review.

Tasks:

- Extract pure logic from large Svelte files where needed.
- Test extracted modules directly.
- Keep tests behavior-level:
  - Given these inputs/events.
  - Expect this stable state/output.
- Avoid Svelte render tests unless the behavior cannot reasonably be extracted.

Success criteria:

- New Vitest tests cover real refactor risks.
- Tests remain useful even if the Svelte component structure changes.
- `yarn test:unit` is green.

### 6. Rework Playwright Infra

Create a proper Playwright E2E harness separate from the old component-test harness.

Tasks:

- Add a dedicated Playwright E2E config.
- Add a package script such as `yarn test:e2e`.
- Decide what `yarn test` should mean after migration:
  - Option A: keep `yarn test` for E2E.
  - Option B: make `yarn test` print/use the intended full frontend test command.
  - Option C: reserve `yarn test:e2e` and update docs/scripts accordingly.
- Ensure E2E tests run against the real Rails app in test mode.
- Preserve traces/screenshots/videos on failure.
- Avoid mixing Playwright CT and Playwright E2E in the same command.

Success criteria:

- `test/e2e` or an equivalent directory is included by the E2E config.
- `yarn test:e2e` runs actual browser journeys.
- The old Playwright CT command is no longer confused with E2E coverage.

### 7. Add Deterministic E2E Setup

Make E2E reliable by giving it deterministic server-side setup and mutation hooks.

Tasks:

- Add test-only setup helpers for:
  - Users.
  - Accounts.
  - Agents.
  - Conversations.
  - Memberships/permissions.
- Add deterministic model-response helpers for:
  - Normal assistant messages.
  - Thinking-mode responses.
  - Streaming/final message transitions.
  - Multi-agent responses.
- Add safe test-only mutation hooks for sync tests, if needed.

Constraints:

- Test-only code must be unavailable outside test environment.
- Do not call real AI providers from E2E tests.
- Do not depend on long sleeps where a direct condition can be awaited.
- Avoid destructive operations against the development database.

Success criteria:

- E2E setup is fast and deterministic.
- Tests do not require live external API access.
- Sync tests can trigger real server-side changes through safe test-only routes or real UI flows.

### 8. Build Core E2E Contract Suite

Write a small suite of high-value browser journeys.

Initial tests:

1. Login flow.
  - User can log in.
  - User lands in the expected authenticated area.
2. Multi-agent conversation creation.
  - User can create or open a conversation.
  - User can assign/select multiple agents.
3. Chat with agents.
  - User sends a message.
  - Assistant/agent messages appear.
  - Final message state is visible.
4. Thinking mode.
  - Thinking-capable agent uses thinking mode. (test across at least Claude and Gemini, multi-turn and multi-agent)
  - UI represents thinking correctly.
  - Non-thinking agents do not incorrectly show thinking state.
5. Streaming and final states.
  - Streaming state appears.
  - Final content replaces or completes the streaming state.
  - No duplicate or stuck streaming messages remain.
6. Cross-window/user sync.
  - Two browser contexts view the same relevant area.
  - One context or test hook changes server state.
  - The other context updates through Action Cable and Inertia.

Success criteria:

- The suite is small enough to run before deployments or major refactors.
- Failures point to meaningful product regressions.
- Tests cover the flows that make Svelte refactoring risky.

### 9. Retire Old Playwright CT Suite

Once E2E coverage exists, remove or quarantine the old Playwright Component Tests.

Tasks:

- Review each CT file for any uniquely valuable behavior.
- Move any useful behavior into Vitest or E2E, depending on the layer.
- Delete the rest.
- Remove stale docs that describe Playwright CT as the primary frontend strategy.

Success criteria:

- The old CT suite is no longer part of the standard test path.
- Browser confidence comes from E2E, not component inventory tests.

### 10. Proceed To Svelte Refactor

Only after the new safety net is in place, we are ready to begin the Svelte cleanup/refactor. Pause and discuss with Daniel before proceeding.

## Open Decisions

- Should `yarn test` eventually mean E2E, or should E2E live only behind `yarn test:e2e`?
  - Answer: you and Claude will be the one running it so I think it makes little difference.
- Should the old Playwright CT files be deleted immediately after E2E exists, or quarantined for one release cycle?
  - Answer: I think you can delete them, they haven't been run in many months and are saved in Github.
- Which current Ruby mocks are acceptable to keep after review?
  - Answer: Only ones approved explicitly by Daniel, and the justification for why VCR could not be used should be added as a comment.
- Should E2E run automatically in CI, or only as a manually triggered/pre-deploy job?
  - We're not really doing CI here - single dev setup atm - so it will be manually triggered on this machine.

## Suggested Execution Order

1. Fix Rails green baseline.
2. Audit Ruby mocks and convert obvious VCR candidates.
3. Quarantine/delete noisy Vitest tests.
4. Run sub-agent Svelte review.
5. Add focused Vitest tests for pre-refactor seams.
6. Build E2E infrastructure and deterministic setup.
7. Add the first 3-4 E2E contract tests.
8. Retire Playwright CT.
9. Add remaining E2E sync/thinking coverage.
10. Confirm new status so we an start discussing the Svelte refactor.

## Implementation Progress

This section records progress against the plan without rewriting the original observations above.

### 2026-05-03 Initial Implementation Pass

- Rails baseline is green after fixing the chats index `Select.Value` build issue and updating the `Agent#as_json` memory stats assertion.
- `bin/rails test` passes with `1834 runs, 7324 assertions, 0 failures, 0 errors`.
- Noisy Vitest page/layout/form render tests have been removed.
- Focused Vitest tests now cover message visibility, streaming state, sync maps, upload rules, cable event classification, token helpers, and tool label formatting.
- `yarn test:unit --run` passes with 7 files and 23 tests.
- A dedicated Playwright E2E config and runner now exist.
- `yarn test:e2e` runs real browser journeys through `playwright/run-e2e.sh`.
- `yarn test` now aliases to the E2E suite, while the old Playwright CT harness remains available as `yarn test:ct`.
- The E2E suite currently covers login, multi-agent chat creation, deterministic thinking output, and cross-window message sync.
- `yarn test:e2e` passes with 2 browser contract tests.
- Ruby mock audit status moved to `docs/plans/2026-05-03-ruby-mock-audit.md`.

### 2026-05-03 Ruby Mock/VCR Conversion Pass

- RubyLLM moderation, manual agent response, all-agent response, conversation consolidation, memory reflection, memory refinement consent, and agent initiation decision coverage now use VCR-backed provider calls where the provider boundary is part of the behavior.
- GitHub integration, sync job, controller repo loading, and GitHub commits tool tests now use VCR-backed GitHub API calls instead of method or `Net::HTTP` stubs.
- Oura disconnect now records the revoke-token HTTP request through VCR instead of stubbing `revoke_token`.
- Prompt/string construction and parsing edge cases were moved to direct Ruby tests where provider calls would only inspect our own code rather than an external integration boundary.
- Focused converted Rails subset passes with `139 runs, 364 assertions, 0 failures, 0 errors`.
- Full Rails suite passes with `1815 runs, 7295 assertions, 0 failures, 0 errors`.
- `yarn test:unit --run` passes with 7 files and 23 tests.
- `yarn test:e2e` passes with 2 browser contract tests.
- Telegram bot send and webhook controller tests now use VCR-backed Telegram API calls. The one live send was confirmed delivered, and cassettes scrub bot tokens, chat ids, user/bot metadata, and webhook secrets.
- Remaining stubs are now limited to approved carve-outs: ElevenLabs transcription/controller stubs and database backup config/ENV stubs.

### 2026-05-03 Progress Note

This pass has shifted the test suite toward the agreed strategy: Rails tests now cover real application behavior and external integration boundaries through VCR wherever practical; Vitest has been narrowed to frontend state/logic seams that are useful before Svelte refactoring; and Playwright now provides a small, high-value browser contract suite for login, multi-agent chat, thinking display, and cross-window sync. The remaining mock/stub usage is intentionally limited to the approved ElevenLabs audio and database-backup configuration carve-outs.
