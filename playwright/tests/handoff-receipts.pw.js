import { test, expect } from '@playwright/experimental-ct-svelte';
import Harness from '../ChatHandoffHarness.svelte';

// Mira's reviews of #283: a refresh reloads only the recent thirty messages,
// a page fetch or reload can carry a receipt serialized before it moved, and
// a cable reconnect reloads only the recent window. The newest receipt must
// win in every case.

const receipt = (state) => [{ recipient_id: 'mira', recipient_name: 'Mira', state, reason: null }];

const olderPage = (state, version) => ({
  messages: [
    {
      id: 'older-handoff',
      content: 'Mira, ready for your review.',
      role: 'assistant',
      author_name: 'Lume',
      agent_id: 'lume',
      completed: true,
      created_at: '2026-10-10T11:00:00Z',
      handoff_receipts: receipt(state),
      handoff_receipts_version: version,
    },
  ],
  has_more: false,
  oldest_id: 'older-handoff',
});

function announce(page, { chatId = 'room', messageId = 'older-handoff', state, version }) {
  return page.evaluate((detail) => window.dispatchEvent(new CustomEvent('handoff-receipts', { detail })), {
    action: 'handoff_receipts',
    chat_id: chatId,
    message_id: messageId,
    handoff_receipts: receipt(state),
    handoff_receipts_version: version,
  });
}

const olderReceipt = (page) => page.locator('[data-testid="handoff-receipt"]').first();
const recentReceipt = (page) => page.locator('[data-testid="handoff-receipt"]').last();

test('a receipt on a message older than the recent window moves live', async ({ mount, page }) => {
  await page.route('**/*before_id*', (route) => route.fulfill({ json: olderPage('queued', 10) }));
  await mount(Harness);
  await page.getByTestId('load-older').click();
  await expect(olderReceipt(page)).toHaveText('to Mira · queued');

  await announce(page, { chatId: 'another-room', state: 'delivered', version: 20 });
  await expect(olderReceipt(page)).toHaveText('to Mira · queued');

  await announce(page, { state: 'delivered', version: 20 });
  await expect(olderReceipt(page)).toHaveText('to Mira · delivered');
  await expect(olderReceipt(page)).toHaveAttribute('data-state', 'delivered');
});

test('a delivery announced while the older page is in flight survives the stale page', async ({ mount, page }) => {
  let release;
  const held = new Promise((resolve) => (release = resolve));
  await page.route('**/*before_id*', async (route) => {
    await held;
    await route.fulfill({ json: olderPage('queued', 10) });
  });
  await mount(Harness);
  await page.getByTestId('load-older').click();

  await announce(page, { state: 'delivered', version: 20 });
  release();
  await expect(olderReceipt(page)).toHaveText('to Mira · delivered');
});

test('a reload serialized before the delivery does not put the old receipt back', async ({ mount, page }) => {
  await mount(Harness);
  await expect(recentReceipt(page)).toHaveText('to Mira · queued');

  await announce(page, { messageId: 'recent-29', state: 'delivered', version: 20 });
  await expect(recentReceipt(page)).toHaveText('to Mira · delivered');

  await page.getByTestId('stale-reload').click();
  await expect(recentReceipt(page)).toHaveText('to Mira · delivered');
});

test('after a reconnect, older loaded receipts catch up once, for the messages that can still move', async ({
  mount,
  page,
}) => {
  const asked = [];
  await page.route('**/*before_id*', (route) => route.fulfill({ json: olderPage('queued', 10) }));
  await page.route('**/*receipts_for*', (route) => {
    asked.push(new URL(route.request().url()).searchParams.get('receipts_for'));
    return route.fulfill({
      json: { receipts: { 'older-handoff': { handoff_receipts: receipt('delivered'), handoff_receipts_version: 20 } } },
    });
  });
  await mount(Harness);
  await page.getByTestId('load-older').click();
  await expect(olderReceipt(page)).toHaveText('to Mira · queued');

  await page.evaluate(() => window.dispatchEvent(new CustomEvent('chat-sync-connected', { detail: { id: 'room' } })));
  await expect(olderReceipt(page)).toHaveText('to Mira · delivered');
  expect(asked).toEqual(['older-handoff']);
});
