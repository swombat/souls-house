import { test, expect } from '@playwright/experimental-ct-svelte';
import Harness from '../ChatHandoffHarness.svelte';

// Mira's review of #283: a refresh reloads only the recent thirty messages,
// so a receipt under an older message already on screen must be patched in
// place when the house says it moved.
test('a handoff receipt on a message older than the recent window moves live', async ({ mount, page }) => {
  await page.route('**/*before_id*', (route) =>
    route.fulfill({
      json: {
        messages: [
          {
            id: 'older-handoff',
            content: 'Mira, ready for your review.',
            role: 'assistant',
            author_name: 'Lume',
            agent_id: 'lume',
            completed: true,
            created_at: '2026-10-10T11:00:00Z',
            handoff_receipts: [{ recipient_id: 'mira', recipient_name: 'Mira', state: 'queued', reason: null }],
          },
        ],
        has_more: false,
        oldest_id: 'older-handoff',
      },
    })
  );
  await mount(Harness);

  await page.getByTestId('load-older').click();
  const receipt = page.getByTestId('handoff-receipt');
  await expect(receipt).toHaveText('to Mira · queued');

  const announce = (chatId, state) =>
    page.evaluate(
      ([id, receiptState]) =>
        window.dispatchEvent(
          new CustomEvent('handoff-receipts', {
            detail: {
              action: 'handoff_receipts',
              chat_id: id,
              message_id: 'older-handoff',
              handoff_receipts: [{ recipient_id: 'mira', recipient_name: 'Mira', state: receiptState, reason: null }],
            },
          })
        ),
      [chatId, state]
    );

  await announce('another-room', 'delivered');
  await expect(receipt).toHaveText('to Mira · queued');

  await announce('room', 'delivered');
  await expect(receipt).toHaveText('to Mira · delivered');
  await expect(receipt).toHaveAttribute('data-state', 'delivered');
});
