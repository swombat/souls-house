# Testing Quick Reference

## ⚠️ IMPORTANT: Pre-Commit Testing Requirements

**Before considering ANY change complete, you MUST run:**

```bash
# 1. Run Rails backend tests
rails test

# 2. Run Playwright component tests (REAL backend only, NO mocking!)
bun run test

# Both test suites MUST pass before committing changes!
```

**NEVER mock the backend in tests. The user will be VERY UNHAPPY if you create mocked tests.**

## Test Types and Commands

### Unit Tests (Vitest)
- **Location**: `app/frontend/**/*.test.js`
- **Run**: `bun run test:unit`
- **What**: Component logic, utilities, isolated component behavior
- **Environment**: jsdom (simulated browser)

### Component Tests (Playwright CT)
- **Location**: `playwright/tests/pages/*.pw.js`
- **Run**: `bun run test` - Automatically starts Rails backend, runs tests, cleans up
- **Run with UI**: `bun run test:e2e:ui` - Debug with Playwright UI
- **What**: Page components in real browsers, UI interactions, form submissions against REAL backend
- **Environment**: Real browsers with REAL Rails API (NO mocking allowed!)

### Rails Tests
- **Location**: `test/controllers/`, `test/models/`
- **Run**: `rails test`
- **What**: Backend logic, API endpoints, authentication

## Quick Commands

```bash
# Run all Vitest unit tests
bun run test:unit

# Run Vitest with UI
bun run test:unit:ui

# Run all Playwright component tests (REAL backend required)
bun run test  # Automatically starts Rails, runs tests, and cleans up

# Run Playwright with UI for debugging
bun run test:e2e:ui

# Run specific Playwright test
bun x playwright test -c playwright-ct.config.js playwright/tests/pages/login-simple.pw.js

# Run Rails tests
rails test
```

## Creating New Tests

### For a new Svelte component (unit test):
1. Create `app/frontend/lib/components/my-component.test.js`
2. Use `@testing-library/svelte` for rendering
3. Mock Inertia if needed (see existing mocks)

### For a new page component (Playwright):
1. Create `playwright/tests/pages/my-page.pw.js`
2. Import component from `app/frontend/lib/components/`
3. Test against REAL Rails backend (NO mocking!)
4. See `login.pw.js` for patterns

### For a new Rails controller:
1. Create `test/controllers/my_controller_test.rb`
2. Test API responses and authentication
3. Use fixtures for test data

## Test File Naming

- **Unit tests**: `component-name.test.js`
- **Playwright tests**: `page-name.pw.js` (ALL require real backend)
- **Rails tests**: `controller_name_test.rb`

## Coverage Goals

Each page/feature should have:
1. **Unit tests** for component logic
2. **Playwright CT** for UI behavior
3. **Rails tests** for API endpoints
4. **E2E tests** (optional) for critical user flows
