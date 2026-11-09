import { expect, test } from '@playwright/test';

// A tag can hide its conversations from the list (JOyDXe): switch it on in
// the tag editor and the tagged conversation leaves the sidebar without being
// archived; Filter → Hidden brings it back, and picking the tag in the Filter
// menu shows only that tag's conversations.
test('hide from the list, the Filter menu, and a tag filter', async ({ page, request }, testInfo) => {
  const response = await request.post('/test/e2e/setup', { data: { run_id: `hide-from-list-${Date.now()}` } });
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
    const rows = () =>
      nav
        .getByRole('button', { name: /^Change visual tag: / })
        .evaluateAll((buttons) => buttons.map((b) => b.getAttribute('aria-label').replace('Change visual tag: ', '')));

    await page.goto(`${base}/chats/new`);
    await nav.getByRole('button', { name: 'Change visual tag: No tag', exact: true }).first().click();
    await page.getByRole('menuitem', { name: 'Help', exact: true }).click();
    await expect(nav.getByRole('button', { name: 'Change visual tag: Help', exact: true })).toHaveCount(1);
    await page.reload();
    await expect.poll(rows).toEqual(['Help', 'No tag']);

    await page.goto(`${base}/interface`);
    await page.getByRole('button', { name: /^Edit Help/ }).click();
    const form = page.getByRole('form', { name: 'Edit Help', exact: true });
    await form.getByRole('switch', { name: 'Hide conversations with this tag from the list' }).click();
    await form.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect(form).toHaveCount(0);
    await expect(page.getByTestId('visual-tag-hidden-from-list')).toHaveCount(1);

    await page.goto(`${base}/chats/new`);
    await expect.poll(rows).toEqual(['No tag']);
    await page.screenshot({ path: testInfo.outputPath('hidden.png') });

    const filter = nav.getByTestId('chat-filter-trigger');
    await filter.click();
    const menu = page.getByTestId('chat-filter-menu');
    await expect(menu.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
    await expect(menu.getByRole('checkbox', { name: 'Hidden' })).not.toBeChecked();
    await page.screenshot({ path: testInfo.outputPath('filter-menu.png') });
    await menu.getByRole('checkbox', { name: 'Hidden' }).check();
    await expect(page).toHaveURL(/show_hidden=true/);
    await expect.poll(rows).toEqual(['Help', 'No tag']);
    await menu.getByRole('checkbox', { name: 'Hidden' }).uncheck();
    await expect.poll(rows).toEqual(['No tag']);

    await menu.getByRole('button', { name: /Help/ }).click();
    await expect(page).toHaveURL(/tag=/);
    await expect.poll(rows).toEqual(['Help']);
    await page.screenshot({ path: testInfo.outputPath('tag-filter.png') });
    await nav.getByRole('button', { name: 'Stop showing only Help' }).click();
    await expect.poll(rows).toEqual(['No tag']);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
  }
});
