import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatsShow from '../../../app/frontend/pages/chats/show.svelte';

// These are the current serialized chat/message fields, not the old
// content_html/ai_model_name contract. No live provider or resident is used.
const chat = { id: 'chat-123', title: 'Test Conversation', respondable: true, manual_responses: true };
const chats = [
  { id: chat.id, title_or_default: chat.title, updated_at_short: 'Jan 15' },
  { id: 'chat-456', title_or_default: 'Another Chat', updated_at_short: 'Jan 14' },
];
const props = { chat, chats, account: { id: 1 }, messages: [] };
const message = (overrides = {}) => ({
  id: 'msg-1',
  role: 'user',
  content: 'Hello, how are you?',
  author_name: 'John Doe',
  completed: true,
  created_at: '2024-01-15T10:30:00Z',
  ...overrides,
});
const composer = (component) => component.getByTestId('message-composer').getByRole('textbox');
const sendButton = (component) => component.getByRole('button', { name: 'Send message', exact: true });
const messagesUrl = '**/accounts/1/chats/chat-123/messages';

test.describe('Chats Show Page Tests', () => {
  test.use({ timezoneId: 'UTC' });
  test.beforeEach(async ({ page }) => {
    // The composer now saves a versioned draft before sending. Keep this HTTP
    // contract explicit; persistence/concurrency use the real backend in E2E.
    let draft = { content: '', revision: 0 };
    await page.route('**/accounts/1/chats/chat-123/draft', async (route) => {
      if (route.request().method() === 'PATCH') {
        const body = route.request().postDataJSON();
        expect(body.revision).toBe(draft.revision);
        draft = { content: body.content, revision: draft.revision + 1 };
      }
      await route.fulfill({ json: { draft } });
    });
  });
  test('renders an empty respondable chat', async ({ mount }) => {
    const component = await mount(ChatsShow, { props });
    await expect(component).toContainText(chat.title);
    await expect(component).toContainText('Start the conversation by sending a message below');
    await expect(composer(component)).toBeVisible();
    await expect(composer(component)).toBeEnabled();
    await expect(sendButton(component)).toBeDisabled();
    await expect(component).not.toContainText('This conversation has been archived');
  });

  test('keeps routine draft status out of the layout and clears by deleting text', async ({ mount, page }) => {
    const component = await mount(ChatsShow, { props });
    const status = component.getByTestId('message-composer').getByRole('status');
    await expect(status).toHaveText('Saved');
    await expect(status).toHaveClass('sr-only');
    await expect(status).toHaveCSS('position', 'absolute');
    await expect(status).toHaveCSS('height', '1px');
    await composer(component).fill('A draft to delete');
    await expect(status).toHaveClass('sr-only');
    await expect(status).toHaveText('Saved');
    await expect(component.getByRole('button', { name: 'Discard draft' })).toHaveCount(0);
    const cleared = page.waitForRequest(
      (request) =>
        request.url().endsWith('/draft') && request.method() === 'PATCH' && request.postDataJSON().content === ''
    );
    await composer(component).fill('');
    await cleared;
    await expect(status).toHaveText('Saved');
    await expect(sendButton(component)).toBeDisabled();
  });

  test('shows a warning when draft syncing fails', async ({ mount, page }) => {
    await page.route('**/accounts/1/chats/chat-123/draft', (route) => route.abort());
    const component = await mount(ChatsShow, { props });
    const status = component.getByTestId('message-composer').getByRole('status');
    await expect(status).toContainText('Not synced');
    await expect(status).not.toHaveClass('sr-only');
    await expect(status).toBeVisible();
  });

  test('displays user and assistant messages with timestamps', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        ...props,
        messages: [
          message(),
          message({
            id: 'msg-2',
            role: 'assistant',
            author_name: 'Test Assistant',
            content: "I'm doing well, thank you!",
            created_at: '2024-01-15T10:31:00Z',
          }),
        ],
      },
    });
    const list = component.getByTestId('chat-messages');
    await expect(list).toContainText('Hello, how are you?');
    await expect(list).toContainText("I'm doing well, thank you!");
    await expect(list).toContainText('10:30 AM');
    await expect(list).toContainText('10:31 AM');
    await expect(list).not.toContainText('Start the conversation');
  });

  test('enables send only for nonblank input', async ({ mount }) => {
    const component = await mount(ChatsShow, { props });
    await expect(sendButton(component)).toBeDisabled();
    await composer(component).fill('Test message');
    await expect(sendButton(component)).toBeEnabled();
    await composer(component).fill('');
    await expect(sendButton(component)).toBeDisabled();
    await composer(component).fill('   ');
    await expect(sendButton(component)).toBeDisabled();
  });

  test('displays failed assistant response state', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        ...props,
        messages: [message({ role: 'assistant', content: 'Partial response', status: 'failed', completed: false })],
      },
    });
    await expect(component.getByTestId('chat-messages')).toContainText('Failed to generate response');
    // There is no per-message Retry action in the current UI. The composer
    // remains usable; failed-send recovery is exercised separately below.
    await expect(composer(component)).toBeEnabled();
  });

  test('displays a thinking indicator for an empty pending assistant message', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        ...props,
        messages: [
          message(),
          message({ id: 'msg-2', role: 'assistant', content: '', status: 'pending', completed: false }),
        ],
      },
    });
    const list = component.getByTestId('chat-messages');
    await expect(list.getByText('Thinking...', { exact: true })).toBeVisible();
    await expect(list.locator('svg.animate-spin')).toBeVisible();
  });

  test('Shift+Enter inserts a newline and Enter submits once', async ({ mount, page }) => {
    const requests = [];
    await page.route(messagesUrl, async (route) => {
      requests.push(route.request().postData());
      await route.fulfill({
        status: 200,
        json: { message: message({ content: 'Line 1\nLine 2' }), draft: { content: '', revision: 2 } },
      });
    });
    const component = await mount(ChatsShow, { props });
    const input = composer(component);
    await input.fill('Line 1');
    await input.press('Shift+Enter');
    await input.pressSequentially('Line 2');
    await expect(input).toHaveValue('Line 1\nLine 2');
    expect(requests).toHaveLength(0);
    await input.press('Enter');
    await expect(input).toHaveValue('');
    expect(requests).toHaveLength(1);
    expect(requests[0]).toContain('name="message[content]"');
    expect(requests[0]).toMatch(/Line 1\r?\nLine 2/);
  });

  test('groups messages under separate dates', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        ...props,
        messages: [
          message({ content: 'Yesterday message', created_at: '2024-01-14T10:30:00Z' }),
          message({ id: 'msg-2', content: 'Today message' }),
        ],
      },
    });
    const list = component.getByTestId('chat-messages');
    await expect(list).toContainText('Yesterday message');
    await expect(list).toContainText('Today message');
    await expect(list.getByText('Jan 14, 2024', { exact: true })).toBeVisible();
    await expect(list.getByText('Jan 15, 2024', { exact: true })).toBeVisible();
  });

  test('displays the active chat and other chats in the sidebar', async ({ mount }) => {
    const component = await mount(ChatsShow, { props });
    const sidebar = component.getByRole('complementary');
    await expect(sidebar).toContainText(chat.title);
    await expect(sidebar).toContainText('Another Chat');
  });

  test('displays a default title for an untitled chat', async ({ mount }) => {
    const component = await mount(ChatsShow, { props: { ...props, chat: { ...chat, title: null } } });
    await expect(component).toContainText('New Chat');
  });

  test('renders assistant Markdown as formatted content', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: {
        ...props,
        messages: [message({ role: 'assistant', content: 'This is **bold** text with `code`.' })],
      },
    });
    const list = component.getByTestId('chat-messages');
    await expect(list.locator('.prose')).toBeVisible();
    await expect(list.locator('strong')).toHaveText('bold');
    await expect(list.locator('code')).toHaveText('code');
  });

  test('prevents duplicate sends while leaving the draft editable and permits retry', async ({ mount, page }) => {
    let release;
    let attempts = 0;
    await page.route(messagesUrl, async (route) => {
      attempts++;
      if (attempts === 1) {
        await new Promise((resolve) => (release = resolve));
        await route.fulfill({ status: 422, json: { errors: ['Test send failure'] } });
      } else {
        await route.fulfill({
          status: 200,
          json: { message: message({ content: 'Try again' }), draft: { content: '', revision: 2 } },
        });
      }
    });
    const component = await mount(ChatsShow, { props });
    await composer(component).fill('Try again');
    await sendButton(component).click();
    await expect(composer(component)).toBeEnabled();
    await expect(sendButton(component)).toBeDisabled();
    await expect.poll(() => typeof release).toBe('function');
    release();
    await expect(component).toContainText('Test send failure');
    await expect(composer(component)).toBeEnabled();
    await expect(composer(component)).toHaveValue('Try again');
    await sendButton(component).click();
    await expect(composer(component)).toHaveValue('');
    expect(attempts).toBe(2);
  });

  test('disables the composer for archived chats', async ({ mount }) => {
    const component = await mount(ChatsShow, {
      props: { ...props, chat: { ...chat, respondable: false, archived: true } },
    });
    await expect(component).toContainText('This conversation has been archived');
    await expect(composer(component)).toBeDisabled();
    await expect(sendButton(component)).toBeDisabled();
  });
});
