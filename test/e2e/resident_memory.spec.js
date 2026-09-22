import { expect, test } from '@playwright/test';

for (const admin of [false, true]) {
  test(`Memory tab renders ${admin ? 'admin history' : 'member summary'} at desktop and mobile widths`, async ({
    page,
    request,
  }) => {
    const runId = `memory-${admin}-${Date.now()}`;
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      await page.route('**/memory_overview', (route) =>
        route.fulfill({
          json: {
            journals: { count: 123, status: 'measured' },
            node_count: 42,
            edge_count: 89,
            days: Array.from({ length: 14 }, (_, i) => ({
              date: `2026-09-${i + 9}`,
              journals: i % 4,
              nodes: i % 3,
              edges: i % 5,
            })),
          },
        })
      );
      await page.route('**/memory_overview/history?*', (route) => {
        const query = new URL(route.request().url()).searchParams;
        const older = query.has('cursor');
        const include = query.get('kinds').split(',');
        route.fulfill({
          json: {
            archive_status: 'measured',
            next_cursor: older ? null : 'next',
            items: include.includes('journals')
              ? [
                  {
                    id: older ? 'older' : 'journal',
                    kind: 'journals',
                    title: older ? 'Older journal entry' : 'A moment noticed',
                    occurred_at: '2026-09-22T10:00:00.000000Z',
                    timestamp_basis: 'journal heading',
                    path: 'daily-journals/2026-09-22.md',
                    body: '## 10:00 — A moment noticed\nA separate entry, preserved without flattening the whole file.',
                    body_status: 'complete',
                  },
                ]
              : [],
          },
        });
      });
      await page.goto('/login');
      await page.getByLabel(/email/i).fill((admin ? setup.admin_user : setup.primary_user).email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      await page.goto(`/accounts/${setup.account_id}/residents`);
      await page.getByRole('link', { name: 'Edit', exact: true }).first().click();
      await page.getByRole('button', { name: 'Memory', exact: true }).click();
      await expect(page.getByRole('heading', { name: 'Memory', exact: true })).toBeVisible();
      await expect(page.getByText('123', { exact: true })).toBeVisible();
      await expect(page.getByRole('img', { name: /last 14 days/ })).toHaveCount(2);
      if (admin) {
        await expect(page.getByRole('heading', { name: 'A moment noticed' })).toBeVisible();
        for (const label of ['Journals', 'Day summaries', 'Week summaries', 'Month summaries', 'Nodes']) {
          await expect(page.getByRole('checkbox', { name: label, exact: true })).toBeChecked();
        }
        await page.getByRole('button', { name: 'Older', exact: true }).click();
        await expect(page.getByRole('heading', { name: 'Older journal entry' })).toBeVisible();
        await page.getByRole('button', { name: 'Newer', exact: true }).click();
        await expect(page.getByRole('heading', { name: 'A moment noticed' })).toBeVisible();
        await page.getByRole('checkbox', { name: 'Journals', exact: true }).uncheck();
        await expect(page.getByText('No matching memory items.')).toBeVisible();
        await page.getByRole('checkbox', { name: 'Journals', exact: true }).check();
      } else {
        await expect(page.getByRole('region', { name: 'Memory history' })).toHaveCount(0);
      }
      await page.screenshot({ path: `test-results/memory-${admin ? 'admin' : 'member'}-desktop.png`, fullPage: true });
      await page.setViewportSize({ width: 390, height: 844 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.screenshot({ path: `test-results/memory-${admin ? 'admin' : 'member'}-mobile.png`, fullPage: true });
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
    }
  });
}
