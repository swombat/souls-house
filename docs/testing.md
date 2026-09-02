# Testing Strategy

Helix Kit's test suite should protect the behavior that matters while staying cheap enough to run and maintain. The strategy is:

1. Thorough Rails tests for backend behavior and server-rendered contracts.
2. Vitest only for focused frontend logic where it gives clear value.
3. Playwright E2E tests for critical product flows and real browser synchronization.

Avoid tests that merely duplicate implementation details. If a test fails during a good refactor without catching a user-visible or business-relevant regression, it probably belongs in the bin.

## What To Run

For everyday backend or non-visual changes:

```bash
bin/rails test
```

For focused frontend logic changes:

```bash
bun run test:unit
```

For major refactors, synchronization changes, chat/agent changes, or deployment confidence after significant work:

```bash
bun run test
```

Run narrower commands while iterating, then the relevant full suite before considering the work complete. Playwright is intentionally a rarer, heavier confidence check; Rails tests should remain the default safety net.

## Rails Tests

Rails tests are the foundation. They should thoroughly cover models, controllers, integration flows, authorization, Inertia responses, jobs, Action Cable channels, and the server-side behavior behind chat, agents, accounts, whiteboards, and sync.

Use Rails' default Minitest framework:

```bash
# Run all Rails tests
bin/rails test

# Run a specific file
bin/rails test test/controllers/chats_controller_test.rb

# Run a specific test by line
bin/rails test test/models/user_test.rb:15
```

### Ruby Mocking Policy

Do not use mocks, stubs, or fake objects in Ruby tests.

Avoid:

- `Minitest::Mock`
- `stub` and `stub_any_instance`
- Custom fake objects that simulate real API behavior
- Tests that only prove our fake matches our assumptions

Mocks hide integration mistakes. Prefer real records, real requests, real jobs where practical, and recorded real external API responses where direct calls would be too slow or expensive.

### External APIs

Use VCR for external API calls such as LLM APIs and webhooks:

```ruby
VCR.use_cassette("my_api_call") do
  result = SomeService.call_api(params)
  assert_equal expected_value, result
end
```

VCR should record real responses first, then replay them quickly. If streaming or another API shape does not work cleanly with VCR, solve that explicitly rather than falling back to mocks.

### Rails Coverage Priorities

Prioritize Rails tests for:

- Authorization and account scoping.
- Controller and integration flows.
- Inertia response props and redirects.
- Model invariants and callbacks.
- Job behavior and side effects.
- Action Cable channel authorization and broadcasts.
- Chat, agent, message, thinking-mode, tool-use, and sync server contracts.

Use fixtures for stable test data. Do not use factories unless the project explicitly changes direction later.

## Vitest

Vitest is not a broad component/page testing layer. Use it only where it tests stable behavior more cheaply and clearly than Rails or Playwright.

Good Vitest candidates:

- Pure utility functions and frontend data transforms.
- Small state machines extracted from large Svelte components.
- Message streaming/chunk-merging logic.
- Markdown or formatting behavior with important edge cases.
- Keyboard decision logic such as Enter versus Shift+Enter.
- Sync debounce logic, if extracted into testable JavaScript.
- Regression tests for frontend bugs we actually hit.

Poor Vitest candidates:

- Checking that a page has a heading.
- Checking Tailwind classes or DOM wrappers.
- Checking exact placeholder text or marketing copy.
- Duplicating Svelte implementation structure.
- Tests that need a mocked Inertia world to pretend a real flow happened.

Tailwind classes should only be tested when the class itself is the meaningful failure mode, for example a class controlling visibility, accessibility, or a state that users cannot recover from. Otherwise, styling belongs in visual review or E2E coverage of the actual behavior.

Run Vitest with:

```bash
bun run test:unit
bun run test:unit:ui
```

When a Svelte file grows complicated, prefer extracting behavior into a plain JavaScript module and testing that module. Keep the component test surface small.

## Playwright E2E

Playwright E2E is the critical browser confidence layer. It should test a small number of high-value journeys against the real Rails app, not a large inventory of component details.

Use Playwright for flows that only a real browser can prove:

- A user can log in and reach the app.
- A user can create a conversation with multiple agents.
- A user can chat with agents and see messages appear correctly.
- Thinking mode is used and represented correctly in the UI.
- Streaming and final message states behave correctly.
- UI sync works across multiple browser contexts, such as another user or another window seeing updates through Action Cable and Inertia.
- Account scoping prevents users from seeing data they should not see.
- Core mobile/responsive flows remain usable when that is a real product risk.

These tests should be deterministic. Avoid real external AI calls in E2E. Prefer test-only server setup/mutation hooks, VCR-backed behavior, or dedicated test models/routes that let the browser exercise the real app without waiting on unpredictable providers.

### Sync Testing

UI sync is one of the most important reasons to keep Playwright E2E.

The desired pattern is:

1. Create deterministic test users, accounts, agents, and conversations.
2. Open two isolated Playwright browser contexts.
3. Log in as the relevant users.
4. Navigate both contexts through the real app.
5. Trigger a real server-side change through the UI or a test-only endpoint.
6. Assert the other context updates via Action Cable and Inertia reloads.

This is more valuable than testing whether `useSync` has a particular internal shape. The contract is that another real browser sees the right updated UI.

### Frequency

Playwright E2E should run:

- Before deployments after significant changes.
- Before or during major refactors.
- After changing sync, chat, agents, Action Cable, Inertia props, or authentication/session behavior.
- In CI if runtime is acceptable, or as a manually triggered CI job if it is too expensive for every push.

It does not need to be the default command for every small code edit.

## Agent Browser

`agent-browser` remains useful for exploratory manual verification during development. It is not the automated E2E strategy.

Use it to inspect the running app, debug flows, and verify what a user would see:

```bash
agent-browser open http://localhost:3100
agent-browser snapshot -i
agent-browser fill @e2 "test@example.com"
agent-browser click @e5
agent-browser snapshot -i
```

For automated regression coverage, encode the important journey in Playwright instead.

## Test Data

Use fixtures and deterministic setup. Tests should be isolated, repeatable, and safe for the long-lived development database.

Rules:

- Do not run destructive database commands against development data.
- Keep test setup explicit and readable.
- Prefer fixtures for Rails tests.
- Use unique emails or deterministic test records for browser flows.
- Clean test data in the test environment, not in development.

## Writing Effective Tests

Good tests:

- Describe behavior, not implementation.
- Fail for a real regression.
- Are clear about the user or business outcome being protected.
- Use the cheapest layer that can prove the behavior.
- Stay stable across reasonable refactors.

Bad tests:

- Assert private structure.
- Mirror the implementation line by line.
- Require extensive mocks to make the world believable.
- Fail because copy, wrappers, or Tailwind classes changed harmlessly.
- Give confidence in an isolated component while the real app flow is broken.

When in doubt, ask: "Would this test still be valuable if we rewrote the component in a clearer way tomorrow?" If not, move the assertion to a better layer or delete it.
