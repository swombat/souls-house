import { test, expect } from '@playwright/experimental-ct-svelte';
import DeploysPage from '../../app/frontend/pages/admin/deploys.svelte';

const workflows = [
  { key: 'rails', name: 'Deploy Rails', description: 'Rebuild and restart the Rails app from master.' },
  { key: 'runtime', name: 'Rebuild residents', description: 'Rebuild resident images from master.' },
  { key: 'chaos', name: 'Update Chaos', description: 'Adopt the current Chaos release.' },
  { key: 'both', name: 'Deploy both', description: 'Rails and Chaos together.' },
];

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
