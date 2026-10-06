import { expect, test } from '@playwright/test';

async function login(page, setup, user) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

test('GitHub onboarding makes the request and administrator trust boundary visible', async ({
  page,
  request,
  browser,
}, testInfo) => {
  const runId = `github-home-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, github_resident_onboarding: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const adminContext = await browser.newContext({ baseURL: testInfo.project.use.baseURL });
  const admin = await adminContext.newPage();
  try {
    await login(page, setup, setup.primary_user);
    await page.goto(`/accounts/${setup.account_param}/residents/new`);
    await page.getByRole('link', { name: /Bring.*GitHub resident/i }).click();
    await expect(page.getByRole('heading', { name: 'Bring an existing GitHub resident' })).toBeVisible();
    await expect(page.getByText(/token format is not proof of least privilege/i).first()).toBeVisible();
    await page.getByLabel('Resident display name').fill('Example resident');
    await page.getByLabel('Branch (optional)').fill('main');
    await expect(page.getByRole('button', { name: 'Request site-admin review' })).toBeEnabled();
    await page.screenshot({ path: testInfo.outputPath('01-github-request-desktop.png'), fullPage: true });

    // Pending/failed records are synthetic fixtures, not a live GitHub call or
    // Docker launch. Controller/service tests exercise submission and approval.
    await page.goto(setup.github_import_url);
    await expect(page.getByRole('heading', { name: 'Waiting for site-admin review' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Approve repository execution' })).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('02-pending-review.png'), fullPage: true });

    await login(admin, setup, setup.admin_user);
    await admin.goto(setup.github_import_url);
    const approve = admin.getByRole('button', { name: 'Approve repository execution' });
    await expect(approve).toBeDisabled();
    await expect(admin.getByText(/including future pushes/).last()).toBeVisible();
    await admin.getByRole('checkbox', { name: /I approve execution/ }).check();
    await expect(approve).toBeEnabled();
    await admin.screenshot({ path: testInfo.outputPath('03-site-admin-approval.png'), fullPage: true });
    // Deliberately do not approve a fixture or start a container for screenshots.
    await admin.goto(setup.github_import_trust_url);
    await expect(admin.getByRole('heading', { name: 'Home imported; operator trust step needed' })).toBeVisible();
    await expect(admin.getByRole('button', { name: 'Retry activation after operator trust' })).toBeEnabled();
    await admin.screenshot({ path: testInfo.outputPath('05-operator-trust-needed.png'), fullPage: true });

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(setup.github_import_new_url);
    await page.getByLabel('Resident display name').fill('Example resident');
    await page.getByLabel('Branch (optional)').fill('main');
    await expect(page.getByRole('button', { name: 'Request site-admin review' })).toBeEnabled();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('04-github-request-mobile.png'), fullPage: true });

    await page.goto(setup.github_import_failed_url);
    await expect(page.getByRole('heading', { name: 'Import needs attention' })).toBeVisible();
    await expect(page.getByRole('region', { name: 'Import status' }).getByRole('alert')).toContainText(
      'Synthetic setup failure'
    );
    await page.screenshot({ path: testInfo.outputPath('06-import-failure-mobile.png'), fullPage: true });
  } finally {
    await adminContext.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
