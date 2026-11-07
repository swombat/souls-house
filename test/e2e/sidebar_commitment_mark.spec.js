import { expect, test } from '@playwright/test';

// Daniel, 7 Nov (JdwZaj JnwgVy): a thread where a resident has promised to
// come back shows a small mark in the sidebar, and loses it once the
// commitment is delivered or cancelled. The changes arrive live.

async function login(page, user, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(user.email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

test('the sidebar marks a thread with a waiting commitment until it is delivered or cancelled', async ({
  page,
  request,
}, testInfo) => {
  const runId = `commitmark-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  try {
    const make = async (title) => {
      const response = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: title, title, resident_count: 1 },
      });
      expect(response.ok()).toBe(true);
      return response.json();
    };
    const parked = await make('E2E parked thread');
    await make('E2E quiet thread');
    const commitment = async (op, data) => {
      const response = await request.post('/test/e2e/commitment_fixture', { data: { op, ...data } });
      expect(response.ok()).toBe(true);
      return op === 'create' ? response.json() : null;
    };

    const first = await commitment('create', { chat_id: parked.chat_id });

    await login(page, setup.primary_user, setup.password);
    await page.goto(`/accounts/${setup.account_id}/chats/${parked.chat_id}`);
    const sidebar = page.locator('aside');
    const parkedRow = sidebar.getByRole('link', { name: /E2E parked thread/ });
    const quietRow = sidebar.getByRole('link', { name: /E2E quiet thread/ });
    await expect(parkedRow).toBeVisible();
    await expect(quietRow).toBeVisible();

    const mark = parkedRow.getByTestId('commitment-mark');
    await expect(mark).toBeVisible();
    await expect(mark).toHaveAttribute('title', new RegExp(`^${first.resident_name} will come back here `));
    await expect(quietRow.getByTestId('commitment-mark')).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('commitment-mark.png') });

    // Cancelled: the mark goes without a reload.
    await commitment('cancel', { commitment_id: first.commitment_id });
    await expect(mark).toHaveCount(0);

    // A new one brings it back; delivering it takes it away again.
    const second = await commitment('create', { chat_id: parked.chat_id });
    await expect(parkedRow.getByTestId('commitment-mark')).toBeVisible();
    await commitment('deliver', { commitment_id: second.commitment_id });
    await expect(parkedRow.getByTestId('commitment-mark')).toHaveCount(0);

    // And it stays gone after a reload.
    await page.reload();
    await expect(sidebar.getByRole('link', { name: /E2E parked thread/ })).toBeVisible();
    await expect(sidebar.getByTestId('commitment-mark')).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
