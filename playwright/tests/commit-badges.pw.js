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
  'swombat/souls-house@783ab2eefba0ec5dcd303f33642ed8bc387adb3c': 'merged',
  '9c8b7a6': 'unmerged',
  abcdef1: null,
};

test('site admins see deploy status badges on commit ids', async ({ mount, page }) => {
  const requests = [];
  await page.route('**/accounts/acct1/commit_statuses**', (route) => {
    const shas = new URL(route.request().url()).searchParams.get('refs').split(',');
    requests.push(shas);
    const body = { statuses: Object.fromEntries(shas.map((sha) => [sha, statuses[sha] ?? null])) };
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });

  const component = await mount(CommitBadgeHarness, { props: { messages } });

  await expect(component.locator('[data-commit-status]')).toHaveCount(6);
  expect(requests).toHaveLength(1);
  expect(requests[0].sort()).toEqual(
    ['51625a7', '783ab2e', 'swombat/souls-house@783ab2eefba0ec5dcd303f33642ed8bc387adb3c', '9c8b7a6', 'abcdef1'].sort()
  );
  await expect(component.locator('pre [data-commit-status]')).toHaveCount(0);
  await expect(component.locator('[data-commit-status="deployed"]').first()).toHaveAttribute('title', /running build/);
  await page.screenshot({ path: 'tmp/commit-badges.png' });
});

test('readers with no badge repositories see plain text and cause no lookups', async ({ mount, page }) => {
  let requests = 0;
  await page.route('**/accounts/acct1/commit_statuses**', (route) => {
    requests += 1;
    route.fulfill({ status: 404, body: '' });
  });

  const component = await mount(CommitBadgeHarness, { props: { messages, siteAdmin: false } });
  await expect(component.getByText('Is 51625a7 live yet?')).toBeVisible();
  await page.waitForTimeout(300);
  await expect(component.locator('[data-commit-status]')).toHaveCount(0);
  expect(requests).toBe(0);
});

test("an account's connected repository badges its own commits, never as deployed", async ({ mount, page }) => {
  const requests = [];
  await page.route('**/accounts/acct1/commit_statuses**', (route) => {
    const refs = new URL(route.request().url()).searchParams.get('refs').split(',');
    requests.push(refs);
    const known = { '51625a7': 'on_default', 'acme/web@783ab2e': 'off_default' };
    const body = { statuses: Object.fromEntries(refs.map((ref) => [ref, known[ref] ?? null])), revision: 'acme/web=f' };
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });

  const component = await mount(CommitBadgeHarness, {
    props: {
      siteAdmin: false,
      repos: ['acme/web'],
      messages: [
        {
          id: 'm1',
          role: 'user',
          content: 'Landed 51625a7; https://github.com/acme/web/commit/783ab2e is still a branch.',
          created_at: '2026-10-21T12:00:00Z',
        },
      ],
    },
  });

  await expect(component.locator('[data-commit-status]')).toHaveCount(2);
  await expect(component.locator('[data-commit-status="on_default"]')).toHaveAttribute(
    'title',
    'On the default branch'
  );
  await expect(component.locator('[data-commit-status="off_default"]')).toHaveAttribute(
    'aria-label',
    'Not on the default branch'
  );
  await expect(component.locator('[data-commit-status*="deployed"], [title*="master"]')).toHaveCount(0);
  expect(requests[0].sort()).toEqual(['51625a7', 'acme/web@783ab2e']);
  await page.screenshot({ path: 'tmp/commit-badges-account.png' });
});
