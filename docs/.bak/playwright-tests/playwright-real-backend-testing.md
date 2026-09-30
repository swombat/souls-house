# Playwright Component Testing with Rails Backend

## ⚠️ IMPORTANT: This is the ONLY way to test

**NEVER create mocked backend tests. ALL Playwright tests MUST use the real Rails backend.**
**Backend mocking is FORBIDDEN and will make the user VERY UNHAPPY.**

This document describes how Playwright Component Tests work with the Rails backend.

## Overview

Playwright Component Tests run against an actual Rails test server. This is the ONLY approved testing approach - no mocking allowed.

### Benefits

- **Real integration testing**: Tests the actual HTTP flow from component to backend
- **No mocking complexity**: Avoids the need to maintain mock responses
- **Fast execution**: Rails can handle many parallel requests efficiently
- **Real validation**: Tests actual Rails validation and business logic
- **Session handling**: Tests real authentication and session management

## Setup

### Quick Start - Single Command (Recommended)

Run everything with one command that handles the entire flow:

```bash
# Run tests with automatic backend setup and cleanup
bun run test

# Or with UI for debugging
bun run test:e2e:ui
```

This integrated script automatically:
- Drops and recreates the test database
- Runs migrations and seeds test data
- Starts Rails server on port 3200
- Waits for server to be ready
- Runs all Playwright tests
- Cleans up the Rails server when done

### Manual Setup (Alternative)

If you prefer to run the backend and tests separately:

#### 1. Start the Rails Test Server

```bash
bun run test:backend-setup
# or
./playwright/setup-test-server.sh
```

This keeps the Rails server running until you stop it.

#### 2. Run the Component Tests

In a separate terminal:

```bash
# Run all tests
bun x playwright test -c playwright-ct.config.js

# Run with UI for debugging
bun x playwright test -c playwright-ct.config.js --ui

# Run specific test
bun x playwright test -c playwright-ct.config.js playwright/tests/pages/login.pw.js
```

## Architecture

### Component Server (Port 3101)
- Playwright Component Testing server
- Serves the isolated Svelte components
- Runs in the browser

### Rails Test Server (Port 3200)
- Real Rails backend in test environment
- Handles API requests from components
- Uses test database with seeded data


### Request Proxying
- The Playwright component testing server (port 3101) proxies requests to Rails (port 3200)
- Configured in `playwright-ct.config.js` via Vite's server.proxy
- Allows components to make requests to `/login`, `/signup` etc. which get forwarded to Rails

### Inertia Adapter for Tests
- Located in `playwright/test-inertia-adapter.js`
- Provides a `useForm` hook that makes REAL HTTP requests
- Requests go through the Vite proxy to reach the Rails backend
- **NOT A MOCK** - makes actual API calls
- Handles form submissions and responses
- Maintains reactive form state

## Test Data

The test database is seeded with predictable data from `db/seeds/test.rb`:

- **test@example.com** / password: `password123` - For successful login tests
- **existing@example.com** / password: `password123` - For duplicate email tests

These accounts are automatically created when running `bun run test`.
New signups in tests should use timestamp-based emails to avoid conflicts between test runs.

## Writing Tests

### Example Test Structure

```javascript
import { test, expect } from '@playwright/experimental-ct-svelte';
import LoginForm from '../../../app/frontend/lib/components/login-form.svelte';

test.describe('Login Form Component Tests (Real Backend)', () => {
  test('should successfully log in with valid credentials', async ({ mount, page }) => {
    const component = await mount(LoginForm);
    
    // Fill in the form
    await component.locator('input[type="email"]').fill('test@example.com');
    await component.locator('input[type="password"]').fill('password123');
    
    // Submit and wait for real HTTP response
    const responsePromise = page.waitForResponse('**/login');
    await component.locator('button[type="submit"]').click();
    const response = await responsePromise;
    
    // Check the actual response status
    expect(response.status()).toBe(302); // Rails redirect
  });
});
```

### Key Testing Principles

1. **NEVER mock backend responses**: All tests make real HTTP requests
2. **Real response codes**: Rails returns actual status codes (302 for redirects)
3. **Real validation**: Backend performs actual validation
4. **Real session state**: Actual cookies and session management
5. **Real database**: Tests interact with real test database

## Best Practices

1. **Unique test data**: Use timestamps for unique emails in signup tests
2. **Run all tests before committing**: Always run both `rails test` and `bun run test`
3. **Test both success and failure paths**: Verify both valid and invalid inputs
4. **Clean test environment**: The integrated script handles DB setup/teardown automatically
5. **Database cleanup**: The setup script recreates the database each run
6. **Predictable seeds**: Use consistent seed data for reliable tests
7. **Response expectations**: Expect Rails standard responses (302 for redirects)
8. **Parallel execution**: Tests can run in parallel against the same server

## Troubleshooting

### Tests timing out
- Ensure Rails server is running: `curl -I http://localhost:3200`
- Check CORS is configured correctly
- Verify ports (Rails: 3200, Playwright CT: 3101)

### Authentication issues
- Check test users exist in database: `rails console -e test`
- Verify passwords in seed data match test expectations

### Port conflicts
- Kill existing processes: `lsof -ti:3200 | xargs kill -9`
- Ensure no other services use ports 3200 or 3101

## Comparison with Mocked Tests

| Aspect | Mocked Tests | Real Backend Tests |
|--------|--------------|-------------------|
| Speed | Faster (no network) | Slightly slower (real HTTP) |
| Complexity | Mock maintenance | Server setup |
| Coverage | UI behavior only | Full stack |
| Reliability | Mock accuracy | Real behavior |
| Debugging | Easier to isolate | More realistic |

## Future Improvements

- Database transactions/rollback per test
- Parallel test database support
- Automatic server startup in test script
- WebSocket/Action Cable testing
- File upload testing
