import { test, expect } from '@playwright/experimental-ct-svelte';
import MessageComposer from '../../app/frontend/lib/components/chat/MessageComposer.svelte';
import NewChatForm from '../../app/frontend/lib/components/chat/NewChatForm.svelte';

// #453: a voice note whose transcription fails is kept, survives a reload when
// the server has it, and can be retried without recording again. All HTTP is
// intercepted; no provider, credential or real chat is used.

const CHAT = 'chat-123';
const chatPath = `**/accounts/1/chats/${CHAT}/transcription`;
const newPath = '**/accounts/1/chats/transcription';
const recoveryKey = (chat) => `voice-note-recovery:v1:7:1:${chat}`;
const AUDIO_BYTES = 4096;

// Component tests mount without navigating, so the fakes go straight into the
// page. The composer sits at the top of the test page; push it down so the
// card that opens above the mic button is on screen, as it is in the app.
async function fakeMicrophone(page) {
  await page.addStyleTag({ content: 'body { padding-top: 320px; }' });
  await page.evaluate((size) => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) },
    });
    window.MediaRecorder = class {
      static isTypeSupported(type) {
        return type === 'audio/webm';
      }
      constructor() {
        this.mimeType = 'audio/webm';
        this.state = 'inactive';
      }
      start() {
        this.state = 'recording';
      }
      stop() {
        this.state = 'inactive';
        this.ondataavailable({ data: new Blob([new Uint8Array(size).fill(7)], { type: 'audio/webm' }) });
        this.onstop();
      }
    };
  }, AUDIO_BYTES);
}

async function record(component) {
  const mic = component.getByRole('button', { name: 'Record voice message' });
  await mic.click();
  await component.getByRole('button', { name: 'Stop recording' }).click();
}

const card = (component) => component.getByTestId('voice-note-recovery');
const retryButton = (component) => card(component).getByRole('button', { name: 'Retry transcription' });
const savedFailure = (signedId = 'signed-1') => ({
  status: 422,
  json: {
    error: 'Transcription service unavailable. Please try again.',
    retryable: true,
    saved: true,
    audio_signed_id: signedId,
    expires_at: '2026-10-25T12:00:00Z',
  },
});

async function draftRoutes(page) {
  let draft = { content: '', revision: 0 };
  await page.route(`**/accounts/1/chats/${CHAT}/draft`, async (route) => {
    if (route.request().method() === 'PATCH') {
      const body = route.request().postDataJSON();
      draft = { content: body.content, revision: draft.revision + 1 };
    }
    await route.fulfill({ json: { draft } });
  });
  const sends = [];
  await page.route(`**/accounts/1/chats/${CHAT}/messages`, async (route) => {
    sends.push(route.request().postData());
    await route.fulfill({
      json: { message: { id: 'm1', role: 'user', content: 'x' }, draft: { content: '', revision: 99 } },
    });
  });
  return sends;
}

const composerProps = { accountId: 1, chatId: CHAT, userId: 7 };

test.describe('voice note recovery in an existing chat', () => {
  test.beforeEach(async ({ page }) => fakeMicrophone(page));

  test('a saved failure survives a reload and a retry fills the composer without overwriting typed text', async ({
    mount,
    page,
  }) => {
    const sends = await draftRoutes(page);
    const posts = [];
    let answer = savedFailure();
    let releaseRetry;
    await page.route(chatPath, async (route) => {
      posts.push(route.request().postData() || '');
      if (posts.length === 2) await new Promise((resolve) => (releaseRetry = resolve));
      await route.fulfill(answer);
    });

    let component = await mount(MessageComposer, { props: composerProps });
    await record(component);
    await expect(card(component)).toContainText('Voice note not transcribed');
    await expect(card(component)).toContainText('Your recording is saved until');
    await expect(card(component)).toHaveAttribute('data-saved', 'saved');
    expect(JSON.parse(await page.evaluate((key) => localStorage.getItem(key), recoveryKey(CHAT))).signedId).toBe(
      'signed-1'
    );
    await expect(component.getByRole('button', { name: 'Record voice message' })).toHaveCount(0);

    // The reload: a fresh composer finds the saved recording.
    await component.unmount();
    component = await mount(MessageComposer, { props: composerProps });
    await expect(card(component)).toContainText('Your recording is saved until');

    const input = component.getByRole('textbox');
    await input.fill('Something I typed meanwhile');
    answer = { status: 200, json: { text: 'Hello again', audio_signed_id: 'signed-1' } };
    await retryButton(component).click();
    await expect(card(component).getByRole('button', { name: 'Retrying…' })).toBeDisabled();
    await card(component).getByRole('button', { name: 'Retrying…' }).click({ force: true });
    await expect.poll(() => typeof releaseRetry).toBe('function');
    releaseRetry();

    await expect(input).toHaveValue('Something I typed meanwhile\n\nHello again');
    await expect(card(component)).toHaveCount(0);
    expect(posts).toHaveLength(2);
    expect(posts[1]).toContain('name="audio_signed_id"');
    expect(posts[1]).toContain('signed-1');
    expect(posts[1]).not.toContain('name="audio"');
    expect(sends).toHaveLength(0);
    expect(await page.evaluate((key) => localStorage.getItem(key), recoveryKey(CHAT))).toBeNull();
  });

  test('an upload whose answer was lost keeps the bytes in the tab and re-uploads the same recording', async ({
    mount,
    page,
  }) => {
    const sends = await draftRoutes(page);
    const uploads = [];
    await page.route(chatPath, async (route) => {
      uploads.push(route.request().postDataBuffer());
      if (uploads.length === 1) return route.abort('connectionreset');
      await route.fulfill({ json: { text: 'Recovered words', audio_signed_id: 'signed-2' } });
    });

    const component = await mount(MessageComposer, { props: composerProps });
    await record(component);
    await expect(card(component)).toHaveAttribute('data-saved', 'unconfirmed');
    await expect(card(component)).toContainText('not confirmed');
    await expect(card(component)).not.toContainText('Network error');

    await retryButton(component).click();
    await expect(card(component)).toHaveCount(0);
    await expect(component.getByRole('textbox')).toHaveValue('Recovered words');
    expect(uploads).toHaveLength(2);
    const marker = Buffer.alloc(AUDIO_BYTES, 7);
    expect(uploads[0].includes(marker)).toBe(true);
    expect(uploads[1].includes(marker)).toBe(true);
    expect(sends).toHaveLength(0);
    await component.getByRole('button', { name: 'Send message', exact: true }).click();
    await expect.poll(() => sends.length).toBe(1);
    expect(sends[0]).toContain('signed-2');
  });

  test('when this browser cannot remember the recording it says so and discard deletes it', async ({ mount, page }) => {
    await page.evaluate(() => {
      const original = Storage.prototype.setItem;
      Storage.prototype.setItem = function (key, value) {
        if (String(key).startsWith('voice-note-recovery:')) throw new DOMException('full', 'QuotaExceededError');
        return original.call(this, key, value);
      };
    });
    await draftRoutes(page);
    const deletes = [];
    await page.route(chatPath, async (route) => {
      if (route.request().method() === 'DELETE') {
        deletes.push(route.request().postData());
        return route.fulfill({ status: 204, body: '' });
      }
      await route.fulfill(savedFailure('signed-3'));
    });

    const component = await mount(MessageComposer, { props: composerProps });
    await record(component);
    await expect(card(component)).toContainText('This browser could not remember it, so keep this tab open.');

    await card(component).getByRole('button', { name: 'Discard' }).click();
    await expect(card(component)).toHaveCount(0);
    expect(deletes).toHaveLength(1);
    expect(deletes[0]).toContain('signed-3');
  });

  test('a failed discard is not reported as deleted', async ({ mount, page }) => {
    await draftRoutes(page);
    await page.evaluate(
      ([key]) =>
        localStorage.setItem(
          key,
          JSON.stringify({ signedId: 'signed-4', error: 'Timeout', expiresAt: '2099-01-01T00:00:00Z' })
        ),
      [recoveryKey(CHAT)]
    );
    await page.route(chatPath, (route) => route.fulfill({ status: 500, body: 'boom' }));

    const component = await mount(MessageComposer, { props: composerProps });
    await card(component).getByRole('button', { name: 'Discard' }).click();
    await expect(card(component)).toContainText('Could not delete the recording. It is still saved; try again.');
    expect(await page.evaluate((key) => localStorage.getItem(key), recoveryKey(CHAT))).not.toBeNull();
  });

  test('a recording that is no longer on the server ends cleanly', async ({ mount, page }) => {
    await draftRoutes(page);
    await page.evaluate(
      ([key]) =>
        localStorage.setItem(
          key,
          JSON.stringify({ signedId: 'signed-5', error: 'Timeout', expiresAt: '2099-01-01T00:00:00Z' })
        ),
      [recoveryKey(CHAT)]
    );
    await page.route(chatPath, (route) =>
      route.fulfill({
        status: 404,
        json: { error: 'That recording is no longer available.', retryable: false, saved: false },
      })
    );

    const component = await mount(MessageComposer, { props: composerProps });
    await retryButton(component).click();
    await expect(card(component)).toContainText('That recording is no longer available.');
    await expect(retryButton(component)).toHaveCount(0);
    await card(component).getByRole('button', { name: 'Dismiss' }).click();
    await expect(card(component)).toHaveCount(0);
    expect(await page.evaluate((key) => localStorage.getItem(key), recoveryKey(CHAT))).toBeNull();
  });
});

test.describe('voice note recovery before a chat exists', () => {
  test.beforeEach(async ({ page }) => fakeMicrophone(page));

  test('a saved pre-chat failure survives a reload and retry keeps the typed opening', async ({ mount, page }) => {
    const posts = [];
    let answer = savedFailure('signed-new');
    await page.route(newPath, async (route) => {
      posts.push(route.request().postData() || '');
      await route.fulfill(answer);
    });
    const props = {
      userId: 7,
      account: { id: 1 },
      chats: [],
      agents: [{ id: 'agent-1', name: 'Mira' }],
    };

    let component = await mount(NewChatForm, { props });
    await record(component);
    await expect(card(component)).toContainText('Your recording is saved until');
    expect(await page.evaluate((key) => localStorage.getItem(key), recoveryKey('new'))).toContain('signed-new');

    await component.unmount();
    component = await mount(NewChatForm, { props });
    await expect(card(component)).toContainText('Your recording is saved until');

    const input = component.getByTestId('message-composer').getByRole('textbox');
    await input.fill('My opening line');
    answer = { status: 200, json: { text: 'Spoken opening', audio_signed_id: 'signed-new' } };
    await retryButton(component).click();

    await expect(input).toHaveValue('My opening line\n\nSpoken opening');
    await expect(card(component)).toHaveCount(0);
    expect(posts).toHaveLength(2);
    expect(posts[1]).toContain('signed-new');
    expect(await page.evaluate((key) => localStorage.getItem(key), recoveryKey('new'))).toBeNull();
  });
});

// Every retry fills the composer and waits: empty, identical and different drafts alike.
// Nothing is sent or created until the person submits.
const drafts = [
  ['an empty composer', '', 'Spoken words'],
  ['the same words already typed', 'Spoken words', 'Spoken words'],
  ['different words typed', 'Typed first', 'Typed first\n\nSpoken words'],
];

test.describe('a retried transcript never sends by itself', () => {
  test.beforeEach(async ({ page }) => fakeMicrophone(page));

  for (const [label, typed, expected] of drafts) {
    test(`existing chat, ${label}`, async ({ mount, page }) => {
      const sends = await draftRoutes(page);
      await page.evaluate(
        ([key]) =>
          localStorage.setItem(
            key,
            JSON.stringify({ signedId: 's-retry', error: 'Timeout', expiresAt: '2099-01-01T00:00:00Z' })
          ),
        [recoveryKey(CHAT)]
      );
      await page.route(chatPath, (route) =>
        route.fulfill({ json: { text: 'Spoken words', audio_signed_id: 's-retry' } })
      );

      const component = await mount(MessageComposer, { props: composerProps });
      const input = component.getByRole('textbox');
      await input.fill(typed);
      await retryButton(component).click();

      await expect(input).toHaveValue(expected);
      await expect(card(component)).toHaveCount(0);
      await page.waitForTimeout(300);
      expect(sends).toHaveLength(0);

      await component.getByRole('button', { name: 'Send message', exact: true }).click();
      await expect.poll(() => sends.length).toBe(1);
      expect(sends[0]).toContain('s-retry');
    });

    test(`new conversation, ${label}`, async ({ mount, page }) => {
      const creates = [];
      await page.route('**/accounts/1/chats', (route) => {
        creates.push(route.request().method());
        return route.fulfill({ status: 500, body: '' });
      });
      await page.evaluate(
        ([key]) =>
          localStorage.setItem(
            key,
            JSON.stringify({ signedId: 's-new', error: 'Timeout', expiresAt: '2099-01-01T00:00:00Z' })
          ),
        [recoveryKey('new')]
      );
      await page.route(newPath, (route) => route.fulfill({ json: { text: 'Spoken words', audio_signed_id: 's-new' } }));

      const component = await mount(NewChatForm, {
        props: { userId: 7, account: { id: 1 }, chats: [], agents: [{ id: 'agent-1', name: 'Mira' }] },
      });
      const input = component.getByTestId('message-composer').getByRole('textbox');
      await input.fill(typed);
      await retryButton(component).click();

      await expect(input).toHaveValue(expected);
      await expect(card(component)).toHaveCount(0);
      await page.waitForTimeout(300);
      expect(creates).toHaveLength(0);
    });
  }
});
