import { test, expect } from '@playwright/experimental-ct-svelte';
import SiteAdminMenu from '../../app/frontend/lib/components/navigation/SiteAdminMenu.svelte';

const summary = {
  repo: 'swombat/souls-house',
  deployed: { sha: 'a'.repeat(40), short: 'aaaaaaa', dirty: false, booted_at: '2026-10-04T12:00:00Z' },
  master: { sha: 'b'.repeat(40), short: 'bbbbbbb', committed_at: '2026-10-04T14:24:30Z', message: 'Merge #150' },
  behind_by: 2,
};

test('site admin menu shows deployed and last merged commits when opened', async ({ mount, page }) => {
  let requests = 0;
  await page.route('**/admin/deploy_info', (route) => {
    requests += 1;
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(summary) });
  });

  const component = await mount(SiteAdminMenu);
  expect(requests).toBe(0);

  await component.getByText('Site Admin').click();
  const info = page.getByTestId('deploy-info');
  await expect(info).toContainText('Deployed aaaaaaa');
  await expect(info).toContainText('Master bbbbbbb · committed');
  await expect(info).toContainText('Live build is 2 commits behind master');
  expect(requests).toBe(1);
  await expect(page.getByRole('menuitem', { name: 'Deploy' })).toBeVisible();
  await page.screenshot({ path: 'tmp/site-admin-deploy-info.png' });
});

test('a failed lookup says unavailable rather than guessing', async ({ mount, page }) => {
  await page.route('**/admin/deploy_info', (route) => route.fulfill({ status: 500, body: '' }));

  const component = await mount(SiteAdminMenu);
  await component.getByText('Site Admin').click();
  await expect(page.getByTestId('deploy-info')).toHaveText('Deploy info unavailable');
});
