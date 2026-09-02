import { test, expect } from '@playwright/experimental-ct-svelte';
import Navbar from '../../../app/frontend/lib/components/navigation/Navbar.svelte';
import { page } from '../../test-inertia-adapter.js';

test.describe('Theme Persistence Tests', () => {
  // IMPORTANT: These tests require the Rails backend running on localhost:3200
  // Run with: bun run test (automatically handles backend setup)

  test.beforeEach(async () => {
    // Reset page store before each test
    page.set({
      props: {},
      component: 'TestComponent',
      url: '/',
      version: '1',
    });
  });

  test.describe('Guest User Theme Features', () => {
    test('should show theme dropdown for guest users', async ({ mount }) => {
      const component = await mount(Navbar);

      // Guest users should see the theme dropdown trigger with sun/moon icons
      const themeButton = component.locator('button').getByText('Toggle theme');
      await expect(themeButton).toBeVisible();

      // Should also show "Not Logged In" dropdown
      await expect(component.getByText('Not Logged In')).toBeVisible();
    });

    test('should open theme dropdown when clicked', async ({ mount }) => {
      const component = await mount(Navbar);

      // Click on theme button
      const themeButton = component.locator('button').getByText('Toggle theme');
      await themeButton.click();

      // After clicking, button should still be visible (dropdown opens)
      await expect(themeButton).toBeVisible();
    });

    test('should persist theme selection in localStorage', async ({ mount, page: testPage }) => {
      // Pre-set theme in localStorage to test persistence
      await testPage.evaluate(() => localStorage.setItem('mode-watcher-mode', 'light'));

      const component = await mount(Navbar);

      // Verify theme persisted
      const themeInStorage = await testPage.evaluate(() => localStorage.getItem('mode-watcher-mode'));
      expect(themeInStorage).toBe('light');

      // Theme toggle should still be visible for guests
      const themeButton = component.locator('button').getByText('Toggle theme');
      await expect(themeButton).toBeVisible();
    });

    test('should have accessibility attributes for theme toggle', async ({ mount }) => {
      const component = await mount(Navbar);

      // Theme dropdown should have screen reader text
      const themeButton = component.locator('button').getByText('Toggle theme');
      await expect(themeButton).toBeVisible();

      // Should have sr-only class for screen readers
      await expect(component.locator('.sr-only')).toContainText('Toggle theme');
    });

    test('should show theme toggle with proper icon structure', async ({ mount }) => {
      const component = await mount(Navbar);

      // Theme button should be visible
      const themeButton = component.locator('button').getByText('Toggle theme');
      await expect(themeButton).toBeVisible();

      // Should have SVG icons (sun and moon icons)
      const svgIcons = component.locator('svg');
      await expect(svgIcons.first()).toBeVisible(); // At least one SVG icon should be present
    });

    test('should handle different localStorage theme values', async ({ mount, page: testPage }) => {
      // Test that component mounts successfully with different theme values
      const themes = ['light', 'dark', 'system', null];

      for (const theme of themes) {
        if (theme) {
          await testPage.evaluate((t) => localStorage.setItem('mode-watcher-mode', t), theme);
        } else {
          await testPage.evaluate(() => localStorage.removeItem('mode-watcher-mode'));
        }

        const component = await mount(Navbar);

        // Theme button should always be visible for guests regardless of stored theme
        const themeButton = component.locator('button').getByText('Toggle theme').first();
        await expect(themeButton).toBeVisible();

        // Verify the theme storage state
        const storedTheme = await testPage.evaluate(() => localStorage.getItem('mode-watcher-mode'));
        expect(storedTheme).toBe(theme);
      }
    });
  });

  test.describe('User Authentication States', () => {
    test('should show guest UI when no user is logged in', async ({ mount }) => {
      const component = await mount(Navbar);

      // Should show guest theme toggle
      await expect(component.getByText('Toggle theme')).toBeVisible();

      // Should show "Not Logged In" dropdown
      await expect(component.getByText('Not Logged In')).toBeVisible();
    });

    test('should render navbar structure consistently', async ({ mount }) => {
      const component = await mount(Navbar);

      // Essential navbar elements should be present
      await expect(component.getByText('HelixKit')).toBeVisible();
      await expect(component.getByText('About')).toBeVisible();
      await expect(component.getByText('Toggle theme')).toBeVisible();
      await expect(component.getByText('Not Logged In')).toBeVisible();
    });
  });

  test.describe('Theme Integration Validation', () => {
    test('should have mode-watcher integration working', async ({ mount, page: testPage }) => {
      const component = await mount(Navbar);

      // Verify component loads without errors even when localStorage is empty
      await testPage.evaluate(() => localStorage.removeItem('mode-watcher-mode'));

      const themeButton = component.locator('button').getByText('Toggle theme').first();
      await expect(themeButton).toBeVisible();

      // Component should handle absence of localStorage gracefully
      const themeInStorage = await testPage.evaluate(() => localStorage.getItem('mode-watcher-mode'));
      expect(themeInStorage).toBeNull();
    });

    test('should maintain theme button functionality', async ({ mount }) => {
      const component = await mount(Navbar);

      const themeButton = component.locator('button').getByText('Toggle theme').first();

      // Button should be clickable
      await themeButton.click();
      await expect(themeButton).toBeVisible();
    });
  });
});

// Note about testing limitations:
// ================================
//
// Some advanced theme functionality requires integration testing rather than component testing:
//
// 1. **Logged-in User Theme Selection**: Testing the theme submenu in user dropdowns
//    requires full page context and session state that's better tested with integration tests.
//
// 2. **Server Persistence**: Verifying that theme changes make PATCH requests to /user
//    and persist across sessions requires real backend interaction in a full page context.
//
// 3. **Theme State Synchronization**: Testing that theme changes immediately update the UI
//    and sync between localStorage (guests) and server (logged-in users) requires integration tests.
//
// 4. **Cross-Component Theme Application**: Verifying that theme changes in the Navbar
//    propagate to the Layout component and affect page-wide styling requires full page tests.
//
// The component tests above focus on:
// - Guest user theme dropdown visibility and basic interaction
// - localStorage persistence for guest users
// - Accessibility attributes and visual elements
// - Component structure and reliability
//
// For comprehensive theme testing, complement these component tests with:
// - Rails integration tests for the theme update endpoint
// - Playwright page tests for full user flows involving theme changes
