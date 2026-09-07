import { expect, test } from '@playwright/test';

test('simple self-hosting paths hand off to an agent without exposing technical detail', async ({
  page,
  request,
  context,
}) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));

  await page.goto('/');
  await page.getByRole('link', { name: 'Host your own house', exact: true }).click();
  await expect(page).toHaveURL(/\/self-host$/);
  await expect(page).toHaveTitle('Host your own house — souls.house');
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Your agent helps with the rest.');
  await expect(page.getByRole('link', { name: 'Start on souls.house' })).toHaveAttribute(
    'href',
    'https://souls.house/signup'
  );
  await expect(page.getByRole('heading', { name: 'Give your agent the guide.' })).toBeVisible();
  await expect(page.getByText('Hosting is free for now:', { exact: false })).toBeVisible();
  await expect(page.getByRole('heading', { name: '1. Choose a machine' })).toHaveCount(0);

  const helper = page
    .locator('details')
    .filter({ has: page.locator('summary', { hasText: "I don't have an agent yet" }) });
  await expect(helper).not.toHaveAttribute('open');
  await helper.locator('summary').click();
  await expect(helper.getByText('curl -fsSL https://claude.ai/install.sh | bash', { exact: true })).toBeVisible();
  await expect(helper.getByText('irm https://claude.ai/install.ps1 | iex', { exact: true })).toBeVisible();
  await expect(helper.getByRole('link', { name: 'FreeChaOS', exact: true })).toBeVisible();
  await expect(helper.getByRole('link', { name: "Z.ai's GLM", exact: true })).toBeVisible();
  await expect(helper.getByRole('link', { name: 'Kimi', exact: true })).toBeVisible();
  await expect(helper.getByRole('link', { name: 'Codex-Spark', exact: true })).toBeVisible();

  const laptop = page.locator('details').filter({ has: page.getByRole('heading', { name: 'I have an old laptop.' }) });
  const server = page
    .locator('details')
    .filter({ has: page.getByRole('heading', { name: "I'll use an online server." }) });
  await expect(laptop).not.toHaveAttribute('open');
  await expect(server).not.toHaveAttribute('open');
  await laptop.locator('summary').click();
  await expect(laptop.getByText("This erases the laptop's selected drive.", { exact: true })).toBeVisible();
  await expect(laptop.getByRole('link', { name: 'Omarchy', exact: true })).toBeVisible();
  await expect(laptop.getByRole('link', { name: 'under a minute on the fastest machines' })).toBeVisible();
  await server.locator('summary').click();
  await expect(page.getByTestId('server-prompt')).toContainText('Ask about my budget first');
  await expect(page.getByTestId('setup-prompt')).toContainText('Ask where I');
  await expect(page.getByTestId('guide-url')).toContainText(new URL('/self-host.md', page.url()).href);

  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.getByRole('button', { name: 'Copy setup request' }).click();
  await expect(page.getByRole('button', { name: 'Copied', exact: true })).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toContain('/self-host.md');

  for (const width of [390, 768]) {
    await page.setViewportSize({ width, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }

  const markdown = await request.get('/self-host.md');
  expect(markdown.ok()).toBe(true);
  const guide = await markdown.text();
  expect(guide).toContain('Audience: the agent helping a person');
  expect(guide).toContain('## 7. Keep their home safe');
  expect(guide).toContain('**4 GB total**');
  expect(guide).toContain('512 MiB per concurrently active light resident');
  expect(guide).toContain('**Do not lower existing residents');
  expect(guide).not.toMatch(/(?:have|ask|give|tell) your agent/i);
  await page.getByRole('link', { name: 'Read the full technical guide' }).click();
  await expect(page).toHaveURL(/\/self-host\/technical$/);
  await expect(page.getByRole('heading', { name: '1. Choose a machine' })).toBeVisible();
  const contents = page.getByRole('navigation', { name: 'On this page' });
  for (const link of await contents.locator('a[href^="#"]').all()) {
    const target = await link.getAttribute('href');
    await expect(page.locator(`[id="${target.slice(1)}"]`)).toHaveCount(1);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.getByRole('link', { name: 'Back to the simple steps' }).click();
  await expect(page).toHaveURL(/\/self-host$/);
  expect(errors).toEqual([]);
});
