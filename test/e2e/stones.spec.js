import { expect, test } from '@playwright/test';

test('public stone renders outside the account and preserves revision links', async ({ page, request }, testInfo) => {
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: `stones-${Date.now()}` } });
  const setup = await setupResponse.json();
  try {
    const fixtureResponse = await request.post('/test/e2e/stone_fixture', { data: { account_id: setup.account_id } });
    expect(fixtureResponse.ok()).toBe(true);
    const fixture = await fixtureResponse.json();
    await page.goto(fixture.url);
    await expect(page.getByRole('heading', { name: 'A first stone' })).toBeVisible();
    await expect(page.getByRole('link', { name: /Newer revision/ })).toBeVisible();
    const frame = page.frameLocator('iframe');
    await expect(frame.getByRole('heading', { name: 'Two ways to explain an idea' })).toBeVisible();
    await frame.getByText('Why both?').click();
    await expect(frame.getByText('The page supports the conversation, not the other way round.')).toBeVisible();
    expect(await page.locator('iframe').evaluate((el) => el.contentDocument === null)).toBe(true);
    expect(await page.content()).not.toContain('Private stone source');
    await page.screenshot({ path: testInfo.outputPath('stone-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: testInfo.outputPath('stone-mobile.png'), fullPage: true });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.getByRole('link', { name: /Newer revision/ }).click();
    await expect(page.getByRole('heading', { name: 'A revised stone' })).toBeVisible();
    await page.goto(fixture.chat_url);
    await expect(page).toHaveURL(/login/);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});

test('sandbox and CSP contain hostile stored HTML in-frame and opened directly', async ({
  page,
  request,
  context,
  baseURL,
}) => {
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: `stone-security-${Date.now()}` } });
  const setup = await setupResponse.json();
  try {
    const fixtureResponse = await request.post('/test/e2e/stone_fixture', {
      data: { account_id: setup.account_id, hostile: true },
    });
    expect(fixtureResponse.ok()).toBe(true);
    const fixture = await fixtureResponse.json();
    // Same-host cookies are sent by the browser, but the public controller never
    // loads a house session and the opaque content origin cannot read cookies.
    await context.addCookies([{ name: fixture.cookie_name, value: 'synthetic-cookie', url: baseURL, httpOnly: true }]);
    const delivered = page.waitForRequest((req) => req.url().endsWith(fixture.content_url));
    await page.goto(fixture.url);
    const rawRequest = await delivered;
    expect((await rawRequest.allHeaders()).cookie).toContain('synthetic-cookie');
    const frame = page.frameLocator('iframe');
    await expect(frame.getByRole('heading', { name: 'Hostile storage fixture' })).toBeVisible();
    await expect(frame.locator('body')).not.toHaveAttribute('data-script-ran', 'yes');
    await expect(frame.locator('body')).not.toHaveAttribute('data-event-ran', 'yes');
    expect(await page.locator('iframe').evaluate((el) => el.contentDocument === null)).toBe(true);
    await frame.getByText('Attempt escape').click();
    expect(new URL(page.url()).pathname).toBe(fixture.url);
    await frame.getByText('Attempt submit').click();
    expect(new URL(page.url()).pathname).toBe(fixture.url);
    const rawResponse = await page.goto(fixture.content_url);
    expect(rawResponse.headers()['content-security-policy']).toContain('sandbox;');
    await expect(page.locator('body')).not.toHaveAttribute('data-script-ran', 'yes');
    expect(
      await page.evaluate(() => {
        try {
          return document.cookie;
        } catch (error) {
          return error.name;
        }
      })
    ).toBe('SecurityError');
    // Resource Timing lists successful resource transfers, unlike Playwright's
    // request event, which also reports CSP-blocked attempted requests.
    expect(
      await page.evaluate(() =>
        performance.getEntriesByType('resource').filter((r) => r.name.includes('stone_probe') && r.transferSize > 0)
      )
    ).toEqual([]);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
