# Playwright Component Testing Strategy

## ⚠️ CRITICAL: NO BACKEND MOCKING ALLOWED

**NEVER mock the Rails backend in tests. ALL tests MUST hit the real Rails API.**
**The user will be VERY UNHAPPY if you create mocked backend tests.**

## Overview

This document outlines our testing strategy for Playwright Component Testing in this Rails + Svelte + Inertia.js application. We use Playwright Component Testing to test page-level components (like login and signup forms) in real browsers against the REAL Rails backend.

## Directory Structure

```
playwright/
├── tests/
│   └── pages/                      # Page-level component tests
│       ├── login.pw.js             # Login tests (REAL backend required)
│       └── signup.pw.js            # Signup tests (REAL backend required)
├── test-inertia-adapter.js         # Inertia.js adapter that makes REAL HTTP requests
├── test-routes.js                  # Route helpers
├── MockLink.svelte                 # Mock Link component
├── index.js                        # Test setup
├── run-tests-with-backend.sh       # Script to run tests with Rails backend
└── setup-test-server.sh            # Script to start Rails test server
```

## What We Test vs What We Don't

### ✅ What Playwright Component Tests ARE Good For:

1. **UI Rendering**
   - Verifying all form fields are present
   - Checking text content and labels
   - Ensuring buttons and links are visible

2. **User Interactions**
   - Form field input and validation
   - Button clicks and state changes
   - Navigation link verification

3. **HTML Attributes**
   - Required field validation
   - Input types (email, password, etc.)
   - Link href attributes

4. **Component State**
   - Form values persist correctly
   - Fields can be cleared/reset
   - UI responds to user input

5. **Backend Integration** (ALL tests)
   - Actual API calls to Rails backend
   - Real authentication flow
   - Database state validation
   - Server-side validation responses

## Testing Pattern for New Forms

When adding tests for a new form component, follow this pattern:

### 1. Create a Simple Test File

Create `playwright/tests/pages/your-form-simple.pw.js`:

```javascript
import { test, expect } from '@playwright/experimental-ct-svelte';
import YourForm from '../../../app/frontend/lib/components/your-form.svelte';

test.describe('Your Form Tests', () => {
  test('should render form with all fields', async ({ mount }) => {
    const component = await mount(YourForm);
    
    // Check all elements are present
    await expect(component).toContainText('Expected Title');
    
    // Check form fields
    await expect(component.locator('input[type="email"]')).toBeVisible();
    await expect(component.locator('button[type="submit"]')).toBeVisible();
  });

  test('should accept input in form fields', async ({ mount }) => {
    const component = await mount(YourForm);
    
    const emailInput = component.locator('input[type="email"]');
    
    // Fill and verify
    await emailInput.fill('test@example.com');
    await expect(emailInput).toHaveValue('test@example.com');
  });

  test('should validate required fields', async ({ mount }) => {
    const component = await mount(YourForm);
    
    const emailInput = component.locator('input[type="email"]');
    
    // Check validation attributes
    await expect(emailInput).toHaveAttribute('required', '');
    await expect(emailInput).toHaveAttribute('type', 'email');
  });
});
```

### 2. Form Submission Testing

**NEVER mock backend responses!** Form submissions should hit the real Rails API:

```javascript
test('should submit form to real backend', async ({ mount, page }) => {
  const component = await mount(YourForm);
  
  // Fill form fields
  await component.locator('input[type="email"]').fill('test@example.com');
  
  // Submit and wait for real response
  const responsePromise = page.waitForResponse('**/your-endpoint');
  await component.locator('button[type="submit"]').click();
  const response = await responsePromise;
  
  // Check actual response from Rails
  expect(response.status()).toBe(302); // or whatever Rails returns
});
```

## Test Adapters (NOT Mocks!)

### Inertia.js Adapter

The test adapter (`playwright/test-inertia-adapter.js`) provides a REAL `useForm` implementation that:
- Acts as a Svelte store (subscribable)
- Maintains form state (data, errors, processing)
- **Makes REAL HTTP requests to the Rails backend**
- **NEVER mocks responses - all data comes from Rails**

### Routes

The route helpers (`playwright/test-routes.js`) provide functions that return actual Rails route paths:
```javascript
export const loginPath = () => '/login';  // Real Rails route
export const signupPath = () => '/signup';  // Real Rails route
```

### Link Component

The test Link component (`playwright/MockLink.svelte`) renders as a simple anchor tag:
```svelte
<a {href} class={className} data-method={method} on:click>
  <slot />
</a>
```

## Running Tests

```bash
# Run all Playwright component tests (REAL backend required)
bun run test  # Automatically starts Rails, runs tests, stops Rails

# Run with UI for debugging
bun run test:e2e:ui

# Run with UI mode for debugging
bun run test:ct:ui

# Run specific test file
bun x playwright test -c playwright-ct.config.js playwright/tests/pages/login-simple.pw.js

# Run only on Chrome
bun x playwright test -c playwright-ct.config.js --project chromium
```

### Important: Before Committing Changes

**ALWAYS run both test suites before considering any change complete:**

```bash
# 1. Run Rails tests
rails test

# 2. Run all Playwright component tests (real backend)
bun run test

# Both must pass before committing!
```

## Best Practices

1. **Keep Tests Simple**: Focus on UI behavior, not backend logic
2. **Use Descriptive Names**: Test descriptions should clearly state what's being tested
3. **Test User Perspective**: Test what users see and interact with
4. **Avoid Testing Implementation**: Don't test internal component state or methods
5. **Separate Concerns**: Use simple tests for UI, E2E tests for full flows

## Testing Requirements

### ALL Tests Require Real Backend
- **NO MOCKED TESTS ALLOWED**
- Run against actual Rails server on port 3200
- Test real authentication, database operations, and validation
- Rails server automatically started by `bun run test`
- Use seeded test data from `db/seeds/test.rb`

### Why No Mocking?
1. **Maintenance burden**: Mocks drift from real API behavior
2. **False confidence**: Tests pass with mocks but fail in production
3. **Limited value**: Can't test real validation, auth, or database state
4. **Speed is not an issue**: Real backend tests take only ~5-6 seconds

## When to Use What

| Test Type | Use For | Tool |
|-----------|---------|------|
| **Unit Tests** | Component logic, utilities | Vitest |
| **Component Tests** | UI rendering, user interactions | Playwright CT |
| **E2E Tests** | Full user flows with backend | Playwright E2E |

## Example Test Coverage

For a typical form page, aim for:

### Component Tests (Playwright CT):
- ✅ All form fields render
- ✅ Fields accept and display input
- ✅ Required fields have validation attributes
- ✅ Navigation links point to correct URLs
- ✅ Submit button is present and enabled

### E2E Tests (Separate):
- ✅ Successful form submission
- ✅ Server validation errors display
- ✅ Navigation after submission
- ✅ Session/auth state changes

## Adding Tests for New Pages

1. Create test file in `playwright/tests/pages/`
2. Import the page component from `app/frontend/lib/components/`
3. Write simple UI tests following the patterns above
4. Run tests to verify they pass
5. Add any page-specific mocks if needed

Remember: These tests are for verifying the component renders and responds to user input correctly, not for testing the full application flow.
