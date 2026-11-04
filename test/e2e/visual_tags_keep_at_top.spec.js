import { expect, test } from '@playwright/test';

// Any tag can keep its conversations at the top of the list (#785): switch it
// on in the tag editor, it survives a reload, and the sidebar moves the
// conversation above the others; switching it off lets it fall back.
test('keep at top on an ordinary tag moves its conversations up', async ({ page, request }, testInfo) => {
  const response = await request.post('/test/e2e/setup', { data: { run_id: `keep-at-top-${Date.now()}` } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    for (let i = 0; i < 2; i++) {
      const fixture = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1 },
      });
      expect(fixture.ok()).toBe(true);
    }
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    const base = `/accounts/${setup.account_param}`;
    const nav = page.locator('aside').first();
    const order = () =>
      nav
        .getByRole('button', { name: /^Change visual tag: / })
        .evaluateAll((buttons) => buttons.map((b) => b.getAttribute('aria-label').replace('Change visual tag: ', '')));

    async function tag(current, choice) {
      await nav.getByRole('button', { name: `Change visual tag: ${current}`, exact: true }).first().click();
      await page.getByRole('menuitem', { name: choice, exact: true }).click();
      await expect(nav.getByRole('button', { name: `Change visual tag: ${choice}`, exact: true })).toHaveCount(1);
      await expect(page.getByRole('menu')).toHaveCount(0);
    }

    await page.goto(`${base}/chats/new`);
    // Tagging doesn't reorder the list: the top row gets Help, the lower one Research.
    await tag('No tag', 'Help');
    await tag('No tag', 'Research');
    await page.reload();
    await expect.poll(order).toEqual(['Help', 'Research']);

    async function setKeepAtTop(on) {
      await page.goto(`${base}/interface`);
      await page.getByRole('button', { name: /^Edit Research/ }).click();
      const form = page.getByRole('form', { name: 'Edit Research', exact: true });
      const toggle = form.getByRole('switch', { name: 'Keep conversations with this tag at the top' });
      await expect(toggle).toHaveAttribute('aria-checked', on ? 'false' : 'true');
      await toggle.click();
      await form.getByRole('button', { name: 'Save changes', exact: true }).click();
      await expect(form).toHaveCount(0);
      await page.reload();
      await page.getByRole('button', { name: /^Edit Research/ }).click();
      await expect(
        page
          .getByRole('form', { name: 'Edit Research', exact: true })
          .getByRole('switch', { name: 'Keep conversations with this tag at the top' })
      ).toHaveAttribute('aria-checked', on ? 'true' : 'false');
      await page.screenshot({ path: testInfo.outputPath(`editor-${on ? 'on' : 'off'}.png`) });
    }

    await setKeepAtTop(true);
    await page.goto(`${base}/chats/new`);
    await expect.poll(order).toEqual(['Research', 'Help']);
    await page.screenshot({ path: testInfo.outputPath('sidebar-kept.png') });

    await setKeepAtTop(false);
    await page.goto(`${base}/chats/new`);
    await expect.poll(order).toEqual(['Help', 'Research']);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
  }
});
