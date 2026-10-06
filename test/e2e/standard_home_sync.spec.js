import { expect, test } from '@playwright/test';

test('standard home sync exposes reviewed policy and honest cached outcomes', async ({ page, request }, testInfo) => {
  const runId = `standard-home-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, github_resident_onboarding: true, standard_home_sync: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(setup.github_import_new_url);
    await expect(page.getByRole('radio', { name: 'Keep existing sync' })).toBeChecked();
    await page.getByLabel('Resident display name').fill('Synthetic standard resident');
    await page.screenshot({ path: testInfo.outputPath('01-keep-existing-desktop.png'), fullPage: true });
    await page.getByRole('radio', { name: 'Use standard two-way Git sync' }).check();
    await expect(page.getByText(/uncommitted edits are not automatically\s+saved/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Request site-admin review' })).toBeEnabled();
    await page.screenshot({ path: testInfo.outputPath('02-standard-choice-desktop.png'), fullPage: true });
    // Do not submit or approve: fixtures are synthetic and no repository/runtime is contacted.
    await page.goto(setup.standard_sync_review_url);
    const policy = page.getByRole('region', { name: 'Reviewed home sync policy' });
    await expect(policy.getByText('journals', { exact: true })).toHaveCount(3);
    await expect(policy.getByText(/shrink below 50%/)).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Sync not confirmed' })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('03-reviewed-policy.png'), fullPage: true });

    await page.goto(setup.standard_sync_conflict_url);
    await expect(page.getByRole('heading', { name: 'Sync needs attention' })).toBeVisible();
    await expect(page.getByText(/2 hours ago \(reported age\)/)).toBeVisible();
    await expect(page.getByText(/Local commits pushed to a separate rescue ref/)).toBeVisible();
    await expect(page.getByText('rescue/synthetic/20261006T100000000000Z-abcdef012345')).toBeVisible();
    await expect(page.getByText(/Rescue is not a successful sync/)).toBeVisible();
    await expect(page.getByText(/No site-admin approval is required/)).toBeVisible();
    const healthPosition = await page.getByRole('region', { name: 'Home sync health' }).boundingBox();
    const policyPosition = await page.getByRole('region', { name: 'Reviewed home sync policy' }).boundingBox();
    expect(healthPosition.y).toBeLessThan(policyPosition.y);
    await page.screenshot({ path: testInfo.outputPath('04-conflict-rescue-desktop.png'), fullPage: true });

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(setup.github_import_new_url);
    await page.getByRole('radio', { name: 'Use standard two-way Git sync' }).check();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('05-standard-choice-mobile.png'), fullPage: true });

    await page.goto(setup.standard_sync_rescue_failed_url);
    await expect(page.getByText(/Rescue push failed — keep the local working copy/)).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('06-rescue-failed-mobile.png'), fullPage: true });

    await page.goto(setup.standard_sync_stale_url);
    await expect(page.getByRole('heading', { name: 'Sync report is stale' })).toBeVisible();
    await expect(page.getByText(/None — committed changes only/)).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Last sync check succeeded' })).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('07-stale-mobile.png'), fullPage: true });
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
