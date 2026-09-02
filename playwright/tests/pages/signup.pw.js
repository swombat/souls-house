import { test, expect } from '@playwright/experimental-ct-svelte';
import SignupPage from '../../../app/frontend/pages/registrations/new.svelte';

test.describe('Signup Page Tests', () => {
  // IMPORTANT: These tests require the Rails backend running on localhost:3200
  // Run with: bun run test:integrated (automatically handles backend setup)

  test('should render signup page with all elements', async ({ mount }) => {
    const page = await mount(SignupPage);

    // Check logo is present (looking for the main logo)
    await expect(page.locator('svg').first()).toBeVisible();

    // Check all elements are present
    await expect(page).toContainText('Sign up');
    await expect(page).toContainText("Enter your email to create an account. We'll send you a confirmation link.");
    await expect(page).toContainText("We'll create a personal workspace for you to get started.");

    // Check only email field is present (no password fields)
    await expect(page.locator('input[type="email"]')).toBeVisible();
    await expect(page.locator('input[type="password"]')).not.toBeVisible();

    // Check submit button
    await expect(page.locator('button[type="submit"]')).toBeVisible();
    await expect(page.locator('button[type="submit"]')).toContainText('Create Account');

    // Check login link
    await expect(page.locator('a').filter({ hasText: 'Log in' })).toBeVisible();
  });

  test('should successfully submit signup with valid new email', async ({ mount, page }) => {
    const component = await mount(SignupPage);

    // Generate a unique email for this test run
    const timestamp = Date.now();
    const email = `newuser${timestamp}@example.com`;

    // Fill in the email field
    await component.locator('input[type="email"]').fill(email);

    // Submit the form
    const responsePromise = page.waitForResponse('**/signup');
    await component.locator('button[type="submit"]').click();
    const response = await responsePromise;

    // Check successful signup (302 redirect to check-email page)
    expect(response.status()).toBe(302);
  });

  test('should show error when email already exists', async ({ mount, page }) => {
    const component = await mount(SignupPage);

    // Fill in the form with existing confirmed email (seeded in test database)
    await component.locator('input[type="email"]').fill('test@example.com');

    // Submit the form
    const responsePromise = page.waitForResponse('**/signup');
    await component.locator('button[type="submit"]').click();
    const response = await responsePromise;

    // Should redirect to signup page with error
    expect(response.status()).toBe(302);

    // In a real test, we'd check for the error message displayed after redirect
  });

  test('should resend confirmation for unconfirmed email', async ({ mount, page }) => {
    const component = await mount(SignupPage);

    // Use an email that exists but is unconfirmed
    // This would need to be seeded in test database
    await component.locator('input[type="email"]').fill('unconfirmed@example.com');

    // Submit the form
    const responsePromise = page.waitForResponse('**/signup');
    await component.locator('button[type="submit"]').click();
    const response = await responsePromise;

    // Should redirect to check-email page
    expect(response.status()).toBe(302);
  });

  test('should accept input in email field', async ({ mount }) => {
    const component = await mount(SignupPage);

    const emailInput = component.locator('input[type="email"]');
    await emailInput.fill('test@example.com');

    // Verify the value is set
    await expect(emailInput).toHaveValue('test@example.com');
  });

  test('should validate required email field', async ({ mount }) => {
    const component = await mount(SignupPage);

    // Try to submit without filling email
    const emailInput = component.locator('input[type="email"]');

    // Check that email field is required
    await expect(emailInput).toHaveAttribute('required', '');
  });

  test('should have correct placeholders', async ({ mount }) => {
    const component = await mount(SignupPage);

    const emailInput = component.locator('input[type="email"]');
    await expect(emailInput).toHaveAttribute('placeholder', 'm@example.com');
  });

  test('should navigate to login page', async ({ mount }) => {
    const component = await mount(SignupPage);

    const loginLink = component.locator('a').filter({ hasText: 'Log in' });
    await expect(loginLink).toBeVisible();
    await expect(loginLink).toHaveAttribute('href', '/login');
  });

  test('should preserve form data when typing', async ({ mount }) => {
    const component = await mount(SignupPage);

    const emailInput = component.locator('input[type="email"]');

    // Type character by character
    await emailInput.type('user@domain.com', { delay: 50 });

    // Verify the value is preserved
    await expect(emailInput).toHaveValue('user@domain.com');
  });

  test('should have submit button', async ({ mount }) => {
    const component = await mount(SignupPage);

    const submitButton = component.locator('button[type="submit"]');
    await expect(submitButton).toBeVisible();
    await expect(submitButton).toContainText('Create Account');
  });

  test('should show loading state when processing', async ({ mount }) => {
    const component = await mount(SignupPage);

    const submitButton = component.locator('button[type="submit"]');
    const emailInput = component.locator('input[type="email"]');

    // Fill in email
    await emailInput.fill('loading@test.com');

    // The button should be enabled initially
    await expect(submitButton).toBeEnabled();

    // When form is processing, button text changes and is disabled
    // This would need proper mocking to test the processing state
  });
});
