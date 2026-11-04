import { expect, test } from '@playwright/test';

// Desktop: resting the mouse on a conversation's tag button or ⋯ button opens
// its menu; leaving both the button and the menu closes it. Phones keep tap.
test('chat list menus open on hover on desktop', async ({ page, request }, testInfo) => {
  const response = await request.post('/test/e2e/setup', { data: { run_id: `hover-menus-${Date.now()}` } });
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
    await page.goto(`/accounts/${setup.account_param}/chats/new`);
    const nav = page.locator('aside').first();

    // Tag picker: hover opens, a choice lands, the menu closes.
    const tagButtons = nav.getByRole('button', { name: 'Change visual tag: No tag', exact: true });
    await expect(tagButtons).toHaveCount(2);
    await tagButtons.first().hover();
    const pin = page.getByRole('menuitem', { name: 'Pin', exact: true });
    await expect(pin).toBeVisible();
    // A real hand keeps moving a little. The open menu must not lock the page's
    // pointer events, or the button reads those moves as leaving and the menu flickers.
    const box = await tagButtons.first().boundingBox();
    for (let i = 0; i < 6; i++) {
      await page.mouse.move(box.x + box.width / 2 + (i % 2 ? 2 : -2), box.y + box.height / 2);
      await page.waitForTimeout(120);
    }
    await page.waitForTimeout(400);
    await expect(pin).toBeVisible();
    expect(await page.evaluate(() => getComputedStyle(document.body).pointerEvents)).not.toBe('none');
    await page.screenshot({ path: testInfo.outputPath('tag-hover.png') });
    await pin.hover();
    await page.waitForTimeout(400); // past the close delay: the menu must hold
    await expect(pin).toBeVisible();
    await pin.click();
    await expect(nav.getByRole('button', { name: 'Change visual tag: Pin', exact: true })).toHaveCount(1);
    await expect(page.getByRole('menu')).toHaveCount(0);

    // ⋯ menu: hover opens it; moving away closes it; the next row's opens too.
    const actions = nav.getByRole('button', { name: /^Actions for / });
    await actions.first().hover();
    await expect(page.getByRole('menuitem', { name: 'Archive' })).toBeVisible();
    const dots = await actions.first().boundingBox();
    for (let i = 0; i < 6; i++) {
      await page.mouse.move(dots.x + dots.width / 2 + (i % 2 ? 1 : -1), dots.y + dots.height / 2);
      await page.waitForTimeout(120);
    }
    await page.waitForTimeout(400);
    await expect(page.getByRole('menuitem', { name: 'Archive' })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('actions-hover.png') });
    await page.mouse.move(900, 600);
    await expect(page.getByRole('menu')).toHaveCount(0);
    await actions.nth(1).hover();
    await expect(page.getByRole('menuitem', { name: 'Archive' })).toBeVisible();
    await page.mouse.move(900, 600);
    await expect(page.getByRole('menu')).toHaveCount(0);

    // A click still opens and closes the menu as before.
    await actions.first().click();
    await expect(page.getByRole('menuitem', { name: 'Archive' })).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('menu')).toHaveCount(0);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
  }
});

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

  test('the tag menu waits for a tap', async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', { data: { run_id: `hover-menus-touch-${Date.now()}` } });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      const fixture = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1 },
      });
      expect(fixture.ok()).toBe(true);
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /log in/i }).click();
      await expect(page).not.toHaveURL(/\/login/);
      await page.goto(`/accounts/${setup.account_param}/chats/new`);
      const nav = page.getByRole('navigation', { name: 'Recent conversations' });
      const button = nav.getByRole('button', { name: 'Change visual tag: No tag', exact: true }).first();
      await expect(button).toBeVisible();
      await button.hover();
      await page.waitForTimeout(400);
      await expect(page.getByRole('menu')).toHaveCount(0);
      await button.tap();
      await expect(page.getByRole('menuitem', { name: 'Pin', exact: true })).toBeVisible();
    } finally {
      expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
    }
  });
});
