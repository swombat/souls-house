import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatsIndex from '../../../app/frontend/pages/chats/index.svelte';

test.describe('Chats Index Page Tests', () => {
  // Run through bun run test:ct for an ownership-checked test backend.
  const models = [
    { model_id: 'test/small', label: 'Test Small' },
    { model_id: 'test/large', label: 'Test Large' },
  ];

  test('should render empty state with new chat form', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    // Check welcome message and icon
    await expect(component).toContainText('Start a conversation');
    await expect(component).toContainText('Choose an AI model and begin chatting');
    await expect(component.getByRole('main').locator('svg:visible').first()).toBeVisible();

    // Check new chat form elements
    await expect(component).toContainText('New Chat');
    await expect(component.getByRole('button', { name: 'Select AI model' })).toBeVisible();

    // Check model selector
    const modelSelect = component.locator('[id="model-select"]');
    await expect(modelSelect).toBeVisible();

    // Check start chat button
    const startButton = component.locator('button').filter({ hasText: /Start New Chat/ });
    await expect(startButton).toBeVisible();
    await expect(startButton).toContainText('Start New Chat');
  });

  test('should display chat list when chats exist', async ({ mount }) => {
    const mockChats = [
      {
        id: 'chat-1',
        title_or_default: 'My First Chat',
        updated_at_short: 'Jan 15',
      },
      {
        id: 'chat-2',
        title_or_default: 'Another Conversation',
        updated_at_short: 'Jan 14',
      },
    ];

    const component = await mount(ChatsIndex, {
      props: {
        chats: mockChats,
        account: { id: 1 },
      },
    });

    // Should still show welcome area
    await expect(component).toContainText('Start a conversation');

    // Chat list should be visible in sidebar (via ChatList component)
    // Note: This tests integration with ChatList component
    await expect(component).toContainText('My First Chat');
    await expect(component).toContainText('Another Conversation');
  });

  test('should submit the selected server-provided model', async ({ mount, page }) => {
    // Component boundary: capture the payload without creating a real chat or
    // calling an AI provider. End-to-end tests cover authenticated persistence.
    const requests = [];
    await page.route('**/accounts/1/chats', async (route) => {
      requests.push(route.request().postDataJSON());
      await route.fulfill({ status: 200, json: {} });
    });
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
        models,
      },
    });

    const modelSelect = component.locator('[id="model-select"]');

    // Click to open select
    await modelSelect.click();

    // Should show model options
    await expect(page.getByRole('option', { name: 'Test Small', exact: true })).toBeVisible();
    await expect(page.getByRole('option', { name: 'Test Large', exact: true })).toBeVisible();

    // Select a different model
    await page.getByRole('option', { name: 'Test Large', exact: true }).click();

    // Verify selection
    await expect(modelSelect).toContainText('Test Large');
    await component.getByRole('button', { name: 'Start New Chat' }).click();
    await expect.poll(() => requests).toEqual([{ chat: { model_id: 'test/large' } }]);
  });

  test('should enable/disable create button based on processing state', async ({ mount, page }) => {
    let release;
    await page.route('**/accounts/1/chats', async (route) => {
      await new Promise((resolve) => (release = resolve));
      await route.fulfill({ status: 200, json: {} });
    });
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    const startButton = component.getByRole('button', { name: 'Start New Chat' });

    // Button should be enabled by default
    await expect(startButton).toBeEnabled();

    // Button text should show "Start New Chat" when not processing
    await expect(startButton).toContainText('Start New Chat');

    await startButton.click();
    await expect(component.getByRole('button', { name: 'Creating...' })).toBeDisabled();
    await expect.poll(() => typeof release).toBe('function');
    release();
    await expect(startButton).toBeEnabled();
  });

  test('should have proper accessibility attributes', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    // The compact selector must retain a stable accessible name after selection.
    const modelSelect = component.getByRole('button', { name: 'Select AI model' });
    await expect(modelSelect).toBeVisible();
    await expect(modelSelect).toHaveAttribute('aria-haspopup', 'listbox');

    // Button should be properly accessible
    const startButton = component.locator('button').filter({ hasText: /Start New Chat/ });
    await expect(startButton).toBeVisible();
  });

  test('should display Plus icon in start button', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    const startButton = component.locator('button').filter({ hasText: /Start New Chat/ });

    // Should contain Plus icon (SVG)
    const plusIcon = startButton.locator('svg').first();
    await expect(plusIcon).toBeVisible();
  });

  test('should have proper card structure', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    // Card header with Sparkle icon and title
    await expect(component).toContainText('New Chat');

    // Should have Sparkle icon (check for SVG elements)
    const sparkleIcon = component.getByRole('heading', { name: 'New Chat', exact: true }).locator('svg');
    await expect(sparkleIcon).toBeVisible();

    // Card should contain form elements
    await expect(component.getByRole('button', { name: 'Select AI model' })).toBeVisible();
    await expect(component.locator('[id="model-select"]')).toBeVisible();
    await expect(component.locator('button').filter({ hasText: /Start New Chat/ })).toBeVisible();
  });

  test('should handle empty chats array', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    // Should render without errors
    await expect(component).toBeVisible();
    await expect(component).toContainText('Start a conversation');
  });

  test('should render with minimal required props', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        account: { id: 1 },
        // chats is optional and should default to []
      },
    });

    // Should render without errors
    await expect(component).toBeVisible();
    await expect(component).toContainText('Start a conversation');
  });
});
