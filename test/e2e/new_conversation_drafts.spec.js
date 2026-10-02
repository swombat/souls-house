import { expect, test } from '@playwright/test';

test.describe('unsent first-message recovery', () => {
  let setup, url;
  test.beforeEach(async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `new-draft-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    url = `/accounts/${setup.account_param}/chats`;
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(url);
  });
  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  for (const suffix of ['', '/new']) {
    test(`recovers immediate reload and intended audience from ${suffix || 'index'}`, async ({ page }) => {
      await page.goto(url + suffix);
      await page.getByRole('button', { name: 'E2E Critic', exact: true }).click();
      await page.getByTitle('Edit chat title').click();
      await page.locator('header input[type="text"]').fill('An unsent beginning');
      const input = page.getByTestId('message-composer').locator('textarea');
      await input.fill('First messages deserve custody\nincluding this last keystroke');
      await page.reload();
      await expect(input).toHaveValue('First messages deserve custody\nincluding this last keystroke');
      await expect(page.getByTitle('Edit chat title')).toHaveText('An unsent beginning');
      const posted = page.waitForRequest((req) => req.method() === 'POST' && new URL(req.url()).pathname === url);
      await page.getByRole('button', { name: 'Start conversation' }).click();
      const body = (await posted).postData();
      expect(body).toContain(setup.agents[0].id);
      expect(body).not.toContain(setup.agents[1].id);
      await expect(page).toHaveURL(/\/chats\/(?!new$)[^/]+$/);
      await page.goto(url);
      await expect(input).toHaveValue('');
      await page.reload();
      await expect(input).toHaveValue('');
    });
  }

  test('successful creation clears the browser draft before returning to new', async ({ page }) => {
    const input = page.getByTestId('message-composer').locator('textarea');
    await input.fill('A first message that was actually sent');
    const key = await page.evaluate(() =>
      Object.keys(localStorage).find((key) => key.startsWith('conversation-draft:v1:') && key.endsWith(':new'))
    );
    expect(key).toBeTruthy();
    const stored = await page.evaluate((key) => JSON.parse(localStorage.getItem(key)), key);
    expect(stored.message).toBe('A first message that was actually sent');
    await page.getByRole('button', { name: 'Start conversation' }).click();
    await expect(page).toHaveURL(/\/chats\/(?!new$)[^/]+$/);
    await expect.poll(() => page.evaluate((key) => localStorage.getItem(key), key)).toBeNull();
    await page.goto(url + '/new');
    await expect(input).toHaveValue('');
    expect(await page.evaluate((key) => localStorage.getItem(key), key)).toBeNull();
    await expect(page.getByText(/may already (have been|be) sent/i)).toHaveCount(0);
    await page.reload();
    await expect(input).toHaveValue('');
    expect(await page.evaluate((key) => localStorage.getItem(key), key)).toBeNull();
  });

  test('real refusal redirect and remount retain the unsent text', async ({ page }) => {
    await page.route(`**${url}`, async (route) => {
      const request = route.request();
      if (request.method() !== 'POST') return route.continue();
      // Remove the selected audience at the transport boundary to exercise the
      // controller refusal, not a mocked success callback.
      await route.continue({ postData: request.postData().replaceAll('name="agent_ids[]"', 'name="ignored_ids[]"') });
    });
    const input = page.getByTestId('message-composer').locator('textarea');
    await input.fill('Do not lose this refused first message');
    await page.getByRole('button', { name: 'Start conversation' }).click();
    await expect(page).toHaveURL(url + '/new');
    await expect(input).toHaveValue('Do not lose this refused first message');
    await page.reload();
    await expect(input).toHaveValue('Do not lose this refused first message');
  });

  test('reload before a send acknowledgement warns about possible delivery', async ({ page }) => {
    let intercepted;
    const seen = new Promise((resolve) => (intercepted = resolve));
    await page.route(`**${url}`, async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      intercepted();
      // Leave the request unacknowledged until reload cancels it.
    });
    const input = page.getByTestId('message-composer').locator('textarea');
    await input.fill('A possibly delivered beginning');
    await page.getByRole('button', { name: 'Start conversation' }).click();
    await seen;
    await page.reload();
    await expect(input).toHaveValue('A possibly delivered beginning');
    await expect(page.getByText(/may already (have been|be) sent/i)).toBeVisible();
    await page.screenshot({ path: test.info().outputPath('restored-first-message.png') });
  });
});
