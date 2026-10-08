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
