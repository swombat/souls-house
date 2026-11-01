import { expect, test } from '@playwright/test';

// Settings -> Advanced says where a resident runs: the main house server with
// its early-user note, or its own Hetzner VM by name and size.
test('Advanced settings say which machine a resident is on', async ({ page, request }) => {
  const runId = `hosting-location-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, hosting_location: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const house = setup.agents.find((agent) => agent.name === 'E2E Researcher');
  const vm = setup.agents.find((agent) => agent.name === 'E2E Critic');
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);

    await page.goto(`${house.edit_url}?tab=settings`);
    await expect(page.getByTestId('hosting-location')).toHaveCount(0);
    await page.getByRole('button', { name: 'Advanced settings', exact: true }).click();
    const onHouse = page.getByTestId('hosting-location');
    await expect(onHouse).toContainText(/Directly on the main .+ server/);
    await expect(onHouse).toContainText('free of charge for people who signed up early');
    await onHouse.scrollIntoViewIfNeeded();
    await page.screenshot({ path: 'test-results/hosting-location-house.png', fullPage: true });
    await onHouse.screenshot({ path: 'test-results/hosting-location-house-block.png' });

    await page.goto(`${vm.edit_url}?tab=settings`);
    await page.getByRole('button', { name: 'Advanced settings', exact: true }).click();
    const onVm = page.getByTestId('hosting-location');
    await expect(onVm).toContainText(
      'On its own server: a Hetzner Cloud CX23 (2 vCPUs, 4 GB RAM, 40 GB disk), in Falkenstein, Germany.',
    );
    await expect(onVm).not.toContainText('signed up early');
    await page.screenshot({ path: 'test-results/hosting-location-vm.png', fullPage: true });
    await onVm.screenshot({ path: 'test-results/hosting-location-vm-block.png' });
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
