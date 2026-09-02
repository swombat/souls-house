import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatsIndex from '../../../app/frontend/pages/Chats/index.svelte';

test.describe('Chats Index Page Tests', () => {
  // IMPORTANT: These tests require the Rails backend running on localhost:3200
  // Run with: bun run test:integrated (automatically handles backend setup)

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
    await expect(component.locator('svg')).toBeVisible(); // MessageCircle icon

    // Check new chat form elements
    await expect(component).toContainText('New Chat');
    await expect(component).toContainText('Select AI Model');

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

  test('should handle model selection', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    const modelSelect = component.locator('[id="model-select"]');

    // Click to open select
    await modelSelect.click();

    // Should show model options
    await expect(component).toContainText('GPT-4o Mini');
    await expect(component).toContainText('GPT-4o');
    await expect(component).toContainText('Claude 3.5 Sonnet');
    await expect(component).toContainText('Claude 3.5 Haiku');

    // Select a different model
    await component.locator('[data-value="gpt-4o"]').click();

    // Verify selection
    await expect(modelSelect).toContainText('GPT-4o');
  });

  test('should enable/disable create button based on processing state', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    const startButton = component.locator('button').filter({ hasText: /Start New Chat/ });

    // Button should be enabled by default
    await expect(startButton).toBeEnabled();

    // Button text should show "Start New Chat" when not processing
    await expect(startButton).toContainText('Start New Chat');

    // When processing is true, button should show different text
    // Note: This would require modifying the component state, which isn't
    // easily testable in component tests. This is better tested in E2E.
  });

  test('should have proper accessibility attributes', async ({ mount }) => {
    const component = await mount(ChatsIndex, {
      props: {
        chats: [],
        account: { id: 1 },
      },
    });

    // Model select should have proper label
    const modelLabel = component.locator('label[for="model-select"]');
    await expect(modelLabel).toBeVisible();
    await expect(modelLabel).toContainText('Select AI Model');

    // Select should have proper id
    const modelSelect = component.locator('[id="model-select"]');
    await expect(modelSelect).toBeVisible();

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
    const sparkleIcon = component.locator('svg').nth(1); // Second SVG (first is MessageCircle)
    await expect(sparkleIcon).toBeVisible();

    // Card should contain form elements
    await expect(component.locator('label')).toContainText('Select AI Model');
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
