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

  await mount(SiteAdminMenu);
  expect(requests).toBe(0);

  await page.getByRole('button', { name: 'Site admin menu', exact: true }).click();
  const info = page.getByTestId('deploy-info');
  await expect(info).toContainText('Deployed aaaaaaa');
  await expect(info).toContainText('Master bbbbbbb · committed');
  await expect(info).toContainText('Live build is 2 commits behind master');
  expect(requests).toBe(1);
  await expect(page.getByRole('menuitem', { name: 'Deploy', exact: true })).toBeVisible();
  await page.screenshot({ path: 'tmp/site-admin-deploy-info.png' });
});

test('a failed lookup says unavailable rather than guessing', async ({ mount, page }) => {
  await page.route('**/admin/deploy_info', (route) => route.fulfill({ status: 500, body: '' }));

  await mount(SiteAdminMenu);
  await page.getByRole('button', { name: 'Site admin menu', exact: true }).click();
  await expect(page.getByTestId('deploy-info')).toHaveText('Deploy info unavailable');
  await page.getByRole('menuitem', { name: 'Deploy', exact: true }).click();
  await expect(page.getByRole('menu')).toHaveCount(1);
  await expect(page.getByRole('menu')).toContainText('Couldn’t load deploys');
  await expect(page.getByRole('menuitem', { name: 'Deployments', exact: true })).toBeVisible();
  await expect(page.getByRole('menuitem', { name: 'Deploy Rails', exact: true })).toHaveCount(0);
  await page.getByRole('menuitem', { name: 'Back', exact: true }).click();
  await expect(page.getByRole('menuitem', { name: 'Dashboard', exact: true })).toBeVisible();
  await expect(page.getByTestId('deploy-info')).toHaveText('Deploy info unavailable');
});
