import { expect, test } from '@playwright/test';

test('resident-rich messages persist, sort typed data and render accessible charts on mobile', async ({
  page,
  request,
}, testInfo) => {
  const runId = `rich-ui-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  try {
    const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 0, resident_api_key: true },
    });
    expect(fixtureResponse.ok()).toBe(true);
    const fixture = await fixtureResponse.json();
    const spec = {
      version: 1,
      root: 'report',
      elements: {
        report: { type: 'Card', props: { title: 'An inline research report' }, children: ['metric', 'table', 'chart'] },
        metric: {
          type: 'Metric',
          props: { label: 'Strategies compared', value: '3', detail: 'Illustrative data, not investment results' },
        },
        table: {
          type: 'Table',
          props: {
            title: 'Typed comparison',
            columns: ['Strategy', 'Value'],
            rows: [
              ['Numeric ten', 10],
              ['Numeric two', 2],
              ['Authored string', '1,234'],
              ['Missing', null],
            ],
          },
        },
        chart: {
          type: 'Chart',
          props: {
            title: 'Illustrative comparison',
            kind: 'line',
            labels: ['Week 1', 'Week 2', 'Week 3'],
            series: [
              { name: 'A', values: [100, 110, 105] },
              { name: 'B', values: [100, 98, 108] },
            ],
          },
        },
      },
    };
    const posted = await request.post(`/api/v1/conversations/${fixture.chat_id}/messages`, {
      headers: { Authorization: `Bearer ${fixture.resident_api_key}` },
      data: {
        content: 'Illustrative figures only; the underlying numbers are available with the chart.',
        rich_ui: spec,
      },
    });
    expect(posted.status(), await posted.text()).toBe(201);
    const messageId = (await posted.json()).message.id;
    const read = await request.get(`/api/v1/conversations/${fixture.chat_id}/messages/${messageId}/rich_ui`, {
      headers: { Authorization: `Bearer ${fixture.resident_api_key}` },
    });
    expect((await read.json()).rich_ui).toEqual(spec);
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    const rich = page.getByTestId('rich-ui');
    await expect(rich.getByText('An inline research report', { exact: true })).toBeVisible();
    await expect(
      page.getByText('Illustrative figures only; the underlying numbers are available with the chart.')
    ).toBeVisible();
    const table = rich.getByRole('table', { name: 'Typed comparison', exact: true });
    await table.getByRole('button', { name: 'Value', exact: true }).click();
    await expect(table.locator('tbody tr').nth(0)).toContainText('Numeric two');
    await expect(table.locator('tbody tr').nth(1)).toContainText('Numeric ten');
    await expect(table.locator('tbody tr').nth(2)).toContainText('Authored string');
    await expect(table.locator('tbody tr').nth(3)).toContainText('Missing');
    await rich.getByRole('searchbox', { name: 'Filter Typed comparison' }).fill('Authored');
    await expect(table.locator('tbody tr')).toHaveCount(1);
    await page.reload();
    await expect(table.locator('tbody tr')).toHaveCount(4);
    await expect(rich.getByRole('img', { name: /Illustrative comparison/ })).toBeVisible();
    await rich.getByText('View chart data table', { exact: true }).click();
    await expect(rich.getByRole('table', { name: 'Illustrative comparison data', exact: true })).toContainText('105');
    await rich.getByText('View rich UI JSON', { exact: true }).click();
    await expect(rich.locator('pre')).toContainText('"version": 1');
    const download = page.waitForEvent('download');
    await rich.getByRole('link', { name: 'Download JSON', exact: true }).click();
    expect((await download).suggestedFilename()).toBe('rich-ui.json');
    await rich.getByText('View rich UI JSON', { exact: true }).click();
    await page.screenshot({ path: testInfo.outputPath('rich-message-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.emulateMedia({ colorScheme: 'dark' });
    await rich.scrollIntoViewIfNeeded();
    await expect(rich).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('rich-message-mobile.png'), fullPage: true });
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
