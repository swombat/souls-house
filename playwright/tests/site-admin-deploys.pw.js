import { test, expect } from '@playwright/experimental-ct-svelte';
import DeploysPage from '../../app/frontend/pages/admin/deploys.svelte';
import SiteAdminMenu from '../../app/frontend/lib/components/navigation/SiteAdminMenu.svelte';

const workflows = [
  { key: 'rails', name: 'Deploy Rails', description: 'Rebuild and restart the Rails app from master.' },
  { key: 'runtime', name: 'Rebuild residents', description: 'Rebuild resident images from master.' },
  { key: 'chaos', name: 'Update Chaos', description: 'Adopt the current Chaos release.' },
  { key: 'both', name: 'Deploy both', description: 'Rails and Chaos together.' },
];

async function mockMenuWorkflows(page) {
  await page.route('**/admin/deploy_info', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ workflows }),
    })
  );
}

async function expectInViewport(page, locator) {
  await expect(locator).toBeVisible();
  const bounds = await locator.boundingBox();
  expect(bounds).not.toBeNull();
  const viewport = page.viewportSize();
  expect(bounds.x).toBeGreaterThanOrEqual(0);
  expect(bounds.y).toBeGreaterThanOrEqual(0);
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(viewport.width);
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(viewport.height);
}

test('mobile Deploy replaces the main panel, Back returns, and closing resets it', async ({ mount, page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockMenuWorkflows(page);
  await mount(SiteAdminMenu);
  const trigger = page.getByRole('button', { name: 'Site admin menu', exact: true });
  await trigger.click();

  const menu = page.getByRole('menu');
  await expect(menu).toHaveCount(1);
  await expectInViewport(page, menu);
  const panel = await menu.elementHandle();
  await page.getByRole('menuitem', { name: 'Deploy', exact: true }).click();

  await expect(menu).toHaveCount(1);
  expect(await panel.evaluate((element) => element.isConnected)).toBe(true);
  await expect(page.getByRole('menuitem', { name: 'Dashboard', exact: true })).toHaveCount(0);
  await expect(page.getByRole('menuitem', { name: 'Deploy', exact: true })).toHaveCount(0);
  await expectInViewport(page, menu);
  await expectInViewport(page, page.getByRole('menuitem', { name: 'Back', exact: true }));
  await expectInViewport(page, page.getByRole('menuitem', { name: 'Deployments', exact: true }));
  for (const workflow of workflows) {
    await expectInViewport(page, page.getByRole('menuitem', { name: workflow.name, exact: true }));
  }
  await page.screenshot({ path: 'tmp/site-admin-mobile-panel.png' });

  await page.getByRole('menuitem', { name: 'Back', exact: true }).click();
  await expect(menu).toHaveCount(1);
  expect(await panel.evaluate((element) => element.isConnected)).toBe(true);
  await expect(page.getByRole('menuitem', { name: 'Dashboard', exact: true })).toBeFocused();
  await expect(page.getByRole('menuitem', { name: 'Deploy', exact: true })).toBeVisible();
  await expect(page.getByRole('menuitem', { name: 'Back', exact: true })).toHaveCount(0);

  await page.getByRole('menuitem', { name: 'Deploy', exact: true }).click();
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await expect(trigger).toBeFocused();
  await trigger.click();
  await expect(page.getByRole('menuitem', { name: 'Dashboard', exact: true })).toBeVisible();
  await expect(page.getByRole('menuitem', { name: 'Deploy', exact: true })).toBeVisible();
  await expect(page.getByRole('menuitem', { name: 'Back', exact: true })).toHaveCount(0);
  await expect(page.getByRole('menuitem', { name: 'Deployments', exact: true })).toHaveCount(0);
});

test('keyboard Enter drills down and Back focuses the first item in each panel', async ({ mount, page }) => {
  await mockMenuWorkflows(page);
  await mount(SiteAdminMenu);
  const trigger = page.getByRole('button', { name: 'Site admin menu', exact: true });
  await trigger.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('menuitem', { name: 'Dashboard', exact: true })).toBeFocused();
  await page.keyboard.press('End');
  await expect(page.getByRole('menuitem', { name: 'Deploy', exact: true })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('menu')).toHaveCount(1);
  const back = page.getByRole('menuitem', { name: 'Back', exact: true });
  await expect(back).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('menuitem', { name: 'Deployments', exact: true })).toBeFocused();
  await page.keyboard.press('Home');
  await expect(back).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('menuitem', { name: 'Dashboard', exact: true })).toBeFocused();
  await expect(back).toHaveCount(0);
});

for (const workflow of workflows) {
  test(`menu ${workflow.name} still confirms before posting its workflow`, async ({ mount, page }) => {
    await mockMenuWorkflows(page);
    const posts = [];
    await page.route('**/admin/deploys', async (route) => {
      if (route.request().method() !== 'POST') return route.abort();
      posts.push(route.request().postDataJSON());
      await route.fulfill({ status: 204, body: '' });
    });
    await mount(SiteAdminMenu);
    const trigger = page.getByRole('button', { name: 'Site admin menu', exact: true });
    const openDeploy = async () => {
      await trigger.click();
      await page.getByRole('menuitem', { name: 'Deploy', exact: true }).click();
      await expect(page.getByRole('menuitem', { name: workflow.name, exact: true })).toBeVisible();
    };

    await openDeploy();
    const cancelled = page.waitForEvent('dialog');
    const cancelClick = page.getByRole('menuitem', { name: workflow.name, exact: true }).click();
    const cancelDialog = await cancelled;
    expect(cancelDialog.type()).toBe('confirm');
    expect(cancelDialog.message()).toBe(`Run "${workflow.name}" on master now?`);
    await cancelDialog.dismiss();
    await cancelClick;
    await expect(page.getByRole('menu')).toHaveCount(0);
    expect(posts).toEqual([]);

    await openDeploy();
    const confirmed = page.waitForEvent('dialog');
    const post = page.waitForRequest(
      (request) => request.url().endsWith('/admin/deploys') && request.method() === 'POST'
    );
    const confirmClick = page.getByRole('menuitem', { name: workflow.name, exact: true }).click();
    const confirmDialog = await confirmed;
    expect(confirmDialog.message()).toBe(`Run "${workflow.name}" on master now?`);
    await confirmDialog.accept();
    await confirmClick;
    expect((await post).postDataJSON()).toEqual({ workflow: workflow.key });
    await expect.poll(() => posts).toEqual([{ workflow: workflow.key }]);
  });
}

const runs = [
  {
    id: 2,
    workflow: 'rails',
    name: 'Deploy Rails',
    status: 'in_progress',
    conclusion: null,
    head_sha: 'abcdef1',
    actor: 'swombat',
    created_at: '2026-10-08T06:00:00Z',
    url: 'https://github.com/swombat/souls-house/actions/runs/2',
  },
  {
    id: 1,
    workflow: 'both',
    name: 'Deploy both',
    status: 'completed',
    conclusion: 'success',
    head_sha: '1234567',
    actor: 'swombat',
    created_at: '2026-10-07T18:00:00Z',
    url: 'https://github.com/swombat/souls-house/actions/runs/1',
  },
];

test('deploy page lists the four workflows and recent runs', async ({ mount, page }) => {
  const component = await mount(DeploysPage, {
    props: {
      workflows,
      repo: 'swombat/souls-house',
      deploy_status: { configured: true, runs, token_expires_at: null, error: null },
    },
  });

  for (const workflow of workflows) await expect(component).toContainText(workflow.name);
  const list = page.getByTestId('deploy-runs');
  await expect(list).toContainText('… running');
  await expect(list).toContainText('✓ success');
  await expect(component.getByRole('button', { name: 'Run' }).first()).toBeEnabled();
  await page.screenshot({ path: 'tmp/site-admin-deploys.png', fullPage: true });
});

test('without a token the buttons are disabled and the page says why', async ({ mount, page }) => {
  const component = await mount(DeploysPage, {
    props: { workflows, repo: 'swombat/souls-house', deploy_status: { configured: false, runs: [] } },
  });

  await expect(page.getByTestId('deploy-unconfigured')).toContainText('github.deploy_token');
  await expect(component.getByRole('button', { name: 'Run' }).first()).toBeDisabled();
});

test('a restart mid-run (502) is retried, not an error page, and the run is followed to the end', async ({
  mount,
  page,
}) => {
  // The house answers 502 (mid-restart) until the test releases it.
  let calls = 0;
  let restarted = false;
  await page.route('**/admin/deploys/status', (route) => {
    calls += 1;
    if (!restarted) return route.fulfill({ status: 502, contentType: 'text/html', body: '<h1>Bad gateway</h1>' });
    return route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        configured: true,
        error: null,
        token_expires_at: null,
        runs: [{ ...runs[0], status: 'completed', conclusion: 'success' }],
      }),
    });
  });

  await mount(DeploysPage, {
    props: {
      workflows,
      repo: 'swombat/souls-house',
      pollMs: 200,
      deploy_status: { configured: true, runs: [runs[0]], token_expires_at: null, error: null },
    },
  });

  await expect(page.getByTestId('deploy-poll-error')).toContainText('restarting');
  await expect(page.getByTestId('deploy-runs')).toContainText('… running');
  await expect.poll(() => calls).toBeGreaterThan(2);
  restarted = true;
  await expect(page.getByTestId('deploy-runs').locator('li').first()).toContainText('✓ success');
  await expect(page.getByTestId('deploy-poll-error')).toHaveCount(0);
  const settled = calls;
  await page.waitForTimeout(600);
  expect(calls).toBe(settled);
});
