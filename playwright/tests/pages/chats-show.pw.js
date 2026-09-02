import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatsShow from '../../../app/frontend/pages/Chats/show.svelte';

test.describe('Chats Show Page Tests', () => {
  // IMPORTANT: These tests require the Rails backend running on localhost:3200
  // Run with: bun run test:integrated (automatically handles backend setup)

  const mockChat = {
    id: 'chat-123',
    title: 'Test Conversation',
    ai_model_name: 'GPT-4o Mini',
  };

  const mockAccount = { id: 1 };

  const mockChats = [
    {
      id: 'chat-123',
      title_or_default: 'Test Conversation',
      updated_at_short: 'Jan 15',
    },
    {
      id: 'chat-456',
      title_or_default: 'Another Chat',
      updated_at_short: 'Jan 14',
    },
  ];

  test('should render empty chat with message input', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: [],
        account: mockAccount,
      },
    });

    // Check chat header
    await expect(component).toContainText('Test Conversation');
    await expect(component).toContainText('GPT-4o Mini');

    // Check empty state message
    await expect(component).toContainText('Start the conversation by sending a message below');

    // Check message input area
    const messageInput = component.locator('textarea[placeholder="Type your message..."]');
    await expect(messageInput).toBeVisible();
    await expect(messageInput).toBeEnabled();

    // Check send button
    const sendButton = component.locator('button').last(); // Send button is the last button
    await expect(sendButton).toBeVisible();
    await expect(sendButton).toBeDisabled(); // Should be disabled when input is empty
  });

  test('should display messages correctly', async ({ mount }) => {
    const mockMessages = [
      {
        id: 'msg-1',
        role: 'user',
        content_html: 'Hello, how are you?',
        user_name: 'John Doe',
        user_avatar_url: '/avatar.jpg',
        completed: true,
        error: null,
        created_at: '2024-01-15T10:30:00Z',
        created_at_formatted: '10:30 AM',
      },
      {
        id: 'msg-2',
        role: 'assistant',
        content_html: "<p>I'm doing well, thank you!</p>",
        user_name: null,
        user_avatar_url: null,
        completed: true,
        error: null,
        created_at: '2024-01-15T10:31:00Z',
        created_at_formatted: '10:31 AM',
      },
    ];

    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: mockMessages,
        account: mockAccount,
      },
    });

    // Should show messages
    await expect(component).toContainText('Hello, how are you?');
    await expect(component).toContainText("I'm doing well, thank you!");

    // Should show timestamps
    await expect(component).toContainText('10:30 AM');
    await expect(component).toContainText('10:31 AM');

    // Should not show empty state
    await expect(component).not.toContainText('Start the conversation');
  });

  test('should handle message input and send button state', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: [],
        account: mockAccount,
      },
    });

    const messageInput = component.locator('textarea[placeholder="Type your message..."]');
    const sendButton = component.locator('button').last();

    // Initially disabled
    await expect(sendButton).toBeDisabled();

    // Type message
    await messageInput.fill('Test message');

    // Should enable send button
    await expect(sendButton).toBeEnabled();

    // Clear input
    await messageInput.fill('');

    // Should disable again
    await expect(sendButton).toBeDisabled();

    // Test with whitespace only
    await messageInput.fill('   ');
    await expect(sendButton).toBeDisabled();
  });

  test('should display failed message with retry button', async ({ mount }) => {
    const failedMessages = [
      {
        id: 'msg-1',
        role: 'user',
        content_html: 'Test question',
        completed: true,
        error: null,
        created_at_formatted: '10:30 AM',
      },
      {
        id: 'msg-2',
        role: 'assistant',
        content_html: 'Partial response',
        completed: false,
        error: 'API timeout',
        status: 'failed',
        created_at_formatted: '10:31 AM',
      },
    ];

    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: failedMessages,
        account: mockAccount,
      },
    });

    // Should show error message
    await expect(component).toContainText('Failed to generate response');

    // Should show retry button
    const retryButton = component.locator('button').filter({ hasText: /Retry/ });
    await expect(retryButton).toBeVisible();
    await expect(retryButton).toContainText('Retry');

    // Should have retry icon (ArrowClockwise)
    const retryIcon = retryButton.locator('svg');
    await expect(retryIcon).toBeVisible();
  });

  test('should display pending message state', async ({ mount }) => {
    const pendingMessages = [
      {
        id: 'msg-1',
        role: 'user',
        content_html: 'What is the weather?',
        completed: true,
        error: null,
        created_at_formatted: '10:30 AM',
      },
      {
        id: 'msg-2',
        role: 'assistant',
        content_html: '',
        completed: false,
        error: null,
        status: 'pending',
        created_at_formatted: '10:31 AM',
      },
    ];

    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: pendingMessages,
        account: mockAccount,
      },
    });

    // Should show thinking message
    await expect(component).toContainText('Thinking...');

    // Should show pending indicator (blue dot)
    await expect(component.locator('span').filter({ hasText: '●' })).toBeVisible();
  });

  test('should handle keyboard shortcuts', async ({ mount, page }) => {
    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: [],
        account: mockAccount,
      },
    });

    const messageInput = component.locator('textarea[placeholder="Type your message..."]');

    // Type a message
    await messageInput.fill('Test message');

    // Test Enter key (should trigger send)
    // Note: In component testing, we can't easily test form submission
    // This would be better tested in E2E tests
    await messageInput.press('Enter');

    // Test Shift+Enter (should add new line, not send)
    await messageInput.fill('Line 1');
    await page.keyboard.press('Shift+Enter');
    await messageInput.type('Line 2');

    const inputValue = await messageInput.inputValue();
    expect(inputValue).toContain('\n'); // Should contain newline
  });

  test('should group messages by date', async ({ mount }) => {
    const messagesWithDifferentDates = [
      {
        id: 'msg-1',
        role: 'user',
        content_html: 'Yesterday message',
        completed: true,
        created_at: '2024-01-14T10:30:00Z',
        created_at_formatted: '10:30 AM',
      },
      {
        id: 'msg-2',
        role: 'user',
        content_html: 'Today message',
        completed: true,
        created_at: '2024-01-15T10:30:00Z',
        created_at_formatted: '10:30 AM',
      },
    ];

    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: messagesWithDifferentDates,
        account: mockAccount,
      },
    });

    // Should display both messages
    await expect(component).toContainText('Yesterday message');
    await expect(component).toContainText('Today message');

    // Should show date separators (these are rendered as formatted dates)
    // The exact format depends on the date formatting logic
    await expect(component.locator('.border-t')).toHaveCount(4); // 2 date separators, each with 2 border elements
  });

  test('should display chat sidebar with active chat', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: [],
        account: mockAccount,
      },
    });

    // Should show chat list in sidebar
    await expect(component).toContainText('Test Conversation');
    await expect(component).toContainText('Another Chat');
  });

  test('should handle chat without title', async ({ mount }) => {
    const chatWithoutTitle = {
      ...mockChat,
      title: null,
    };

    const component = await mount(ChatsShow, {
      props: {
        chat: chatWithoutTitle,
        chats: mockChats,
        messages: [],
        account: mockAccount,
      },
    });

    // Should show default title
    await expect(component).toContainText('New Chat');
  });

  test('should render message content as HTML', async ({ mount }) => {
    const htmlMessages = [
      {
        id: 'msg-1',
        role: 'assistant',
        content_html: '<p>This is <strong>bold</strong> text with <code>code</code>.</p>',
        completed: true,
        error: null,
        created_at_formatted: '10:30 AM',
      },
    ];

    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: htmlMessages,
        account: mockAccount,
      },
    });

    // Should render HTML content properly
    const messageContent = component.locator('.prose');
    await expect(messageContent).toBeVisible();

    // Check that HTML is rendered (bold and code elements)
    await expect(component.locator('strong')).toContainText('bold');
    await expect(component.locator('code')).toContainText('code');
  });

  test('should handle disabled input during processing', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        chat: mockChat,
        chats: mockChats,
        messages: [],
        account: mockAccount,
      },
    });

    const messageInput = component.locator('textarea[placeholder="Type your message..."]');

    // Input should be enabled by default
    await expect(messageInput).toBeEnabled();

    // Note: Testing the disabled state during form submission would require
    // simulating the form processing state, which is better tested in E2E tests
  });
});
