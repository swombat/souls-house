import { expect, test } from '@playwright/test';

async function login(page, setup) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.primary_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

test.describe('conversation draft custody', () => {
  let setup, chatId, url;
  test.beforeEach(async ({ request, page }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `draft-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    setup = await response.json();
    const fixture = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 1 },
    });
    chatId = (await fixture.json()).chat_id;
    url = `/accounts/${setup.account_param}/chats/${chatId}`;
    await login(page, setup);
    await page.goto(url);
    await expect(page.getByTestId('message-composer').getByRole('status')).toHaveText('Saved');
  });
  test.afterEach(async ({ request }) => {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  test('typing survives immediate room navigation and reload, and reaches a separate client', async ({
    page,
    browser,
    request,
  }) => {
    const otherResponse = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 1 },
    });
    const otherId = (await otherResponse.json()).chat_id;
    await page.reload();
    const composer = page.getByTestId('message-composer');
    await expect(composer.getByRole('status')).toHaveText('Saved');
    await composer.locator('textarea').fill('Carefully written comments\nwith another line');
    // Use an actual Inertia sidebar link, before the debounce needs to fire.
    await page.locator(`a[href$="/accounts/${setup.account_param}/chats/${otherId}"]`).first().click();
    await expect(page).toHaveURL(new RegExp(`${otherId}$`));
    await page.goBack();
    await expect(composer.locator('textarea')).toHaveValue('Carefully written comments\nwith another line');
    await page.reload();
    await expect(composer.locator('textarea')).toHaveValue('Carefully written comments\nwith another line');
    await expect(composer.getByRole('status')).toHaveText('Saved');

    const context = await browser.newContext({ baseURL: new URL(page.url()).origin });
    const phone = await context.newPage();
    await login(phone, setup);
    await phone.goto(url);
    await expect(phone.getByTestId('message-composer').locator('textarea')).toHaveValue(
      'Carefully written comments\nwith another line'
    );
    await context.close();
  });

  test('offline edits recover across reload, then sync when back online', async ({ page }) => {
    const composer = page.getByTestId('message-composer');
    await page.route('**/draft', (route) => route.abort());
    await composer.locator('textarea').fill('Offline and irreplaceable');
    await expect(composer.getByRole('status')).toContainText('Not synced');
    await page.reload();
    await expect(composer.locator('textarea')).toHaveValue('Offline and irreplaceable');
    await page.unroute('**/draft');
    await page.evaluate(() => window.dispatchEvent(new Event('online')));
    await expect(composer.getByRole('status')).toHaveText('Saved');
    await page.reload();
    await expect(composer.locator('textarea')).toHaveValue('Offline and irreplaceable');
  });

  test('two clients preserve a conflict rather than silently overwriting', async ({ page, browser }, testInfo) => {
    const context = await browser.newContext({ baseURL: new URL(page.url()).origin });
    const second = await context.newPage();
    await login(second, setup);
    await second.goto(url);
    const a = page.getByTestId('message-composer');
    const b = second.getByTestId('message-composer');
    await expect(b.getByRole('status')).toHaveText('Saved');
    await second.route('**/draft', (route) => route.abort());
    await b.locator('textarea').fill('Offline second client');
    await a.locator('textarea').fill('First client version');
    await expect(a.getByRole('status')).toHaveText('Saved');
    await second.unroute('**/draft');
    await second.evaluate(() => window.dispatchEvent(new Event('online')));
    await expect(b.getByRole('alert')).toContainText('First client version');
    await expect(b.locator('textarea')).toHaveValue('Offline second client');
    await second.setViewportSize({ width: 390, height: 844 });
    await second.screenshot({ path: testInfo.outputPath('draft-conflict-mobile.png') });
    await b.getByRole('button', { name: 'Keep my text' }).click();
    await expect(b.getByRole('status')).toHaveText('Saved');
    await page.reload();
    await expect(a.locator('textarea')).toHaveValue('Offline second client');
    await context.close();
  });

  test('failed send retains text and successful send does not erase newer typing', async ({ page }) => {
    const composer = page.getByTestId('message-composer');
    await composer.locator('textarea').fill('The message to send');
    await expect(composer.getByRole('status')).toHaveText('Saved');
    await page.route('**/messages', (route) => {
      if (route.request().method() === 'POST') route.fulfill({ status: 422, json: { errors: ['Try again'] } });
      else route.continue();
    });
    await composer.getByRole('button', { name: 'Send message' }).click();
    await expect(composer.getByRole('button', { name: 'Send message' })).toBeEnabled();
    await expect(composer.locator('textarea')).toHaveValue('The message to send');
    await page.unroute('**/messages');

    let release, serverDone;
    const waiting = new Promise((resolve) => (serverDone = resolve));
    const gate = new Promise((resolve) => (release = resolve));
    await page.route('**/messages', async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      const response = await route.fetch();
      serverDone();
      await gate;
      await route.fulfill({ response });
    });
    await composer.getByRole('button', { name: 'Send message' }).click();
    await waiting;
    await composer.locator('textarea').fill('Already writing the next thought');
    release();
    await expect(composer.getByRole('button', { name: 'Send message' })).toBeEnabled();
    await expect(composer.locator('textarea')).toHaveValue('Already writing the next thought');
    await expect(composer.getByRole('status')).toHaveText('Saved');
    await page.reload();
    await expect(composer.locator('textarea')).toHaveValue('Already writing the next thought');
    await composer.getByRole('button', { name: 'Send message' }).click();
    await expect(composer.locator('textarea')).toHaveValue('');
    await page.reload();
    await expect(composer.locator('textarea')).toHaveValue('');
  });
});
