import { test, expect } from '@playwright/experimental-ct-svelte';
import CommitBadgeHarness from '../CommitBadgeHarness.svelte';

const messages = [
  {
    id: 'user-1',
    role: 'user',
    content: 'Is 51625a7 live yet? And what about 9c8b7a6?',
    created_at: '2026-10-04T12:00:00Z',
  },
  {
    id: 'assistant-1',
    role: 'assistant',
    content: [
      'Merged as `783ab2e`; the dropdown change 51625a7 is live.',
      '',
      '- branch commit 9c8b7a6, not merged',
      '- unknown abcdef1 and Chaos https://github.com/swombat/chaos/commit/51625a7795b2b2369a1aafa009b63093dcafc7d3',
      '- https://github.com/swombat/souls-house/commit/783ab2eefba0ec5dcd303f33642ed8bc387adb3c',
      '',
      '```bash',
      'git revert 51625a7',
      '```',
    ].join('\n'),
    created_at: '2026-10-04T12:01:00Z',
  },
];

const statuses = {
  '51625a7': 'deployed',
  '783ab2e': 'merged',
  '783ab2eefba0ec5dcd303f33642ed8bc387adb3c': 'merged',
  '9c8b7a6': 'unmerged',
  abcdef1: null,
};

test('site admins see deploy status badges on commit ids', async ({ mount, page }) => {
  const requests = [];
  await page.route('**/admin/commit_statuses**', (route) => {
    const shas = new URL(route.request().url()).searchParams.get('shas').split(',');
    requests.push(shas);
    const body = { statuses: Object.fromEntries(shas.map((sha) => [sha, statuses[sha] ?? null])) };
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });

  const component = await mount(CommitBadgeHarness, { props: { messages } });

  await expect(component.locator('[data-commit-status]')).toHaveCount(6);
  expect(requests).toHaveLength(1);
  expect(requests[0].sort()).toEqual(
    ['51625a7', '783ab2e', '783ab2eefba0ec5dcd303f33642ed8bc387adb3c', '9c8b7a6', 'abcdef1'].sort()
  );
  await expect(component.locator('pre [data-commit-status]')).toHaveCount(0);
  await expect(component.locator('[data-commit-status="deployed"]').first()).toHaveAttribute('title', /running build/);
  await page.screenshot({ path: 'tmp/commit-badges.png' });
});

test('people who are not site admins see plain text and cause no lookups', async ({ mount, page }) => {
  let requests = 0;
  await page.route('**/admin/commit_statuses**', (route) => {
    requests += 1;
    route.fulfill({ status: 404, body: '' });
  });

  const component = await mount(CommitBadgeHarness, { props: { messages, siteAdmin: false } });
  await expect(component.getByText('Is 51625a7 live yet?')).toBeVisible();
  await page.waitForTimeout(300);
  await expect(component.locator('[data-commit-status]')).toHaveCount(0);
  expect(requests).toBe(0);
});
