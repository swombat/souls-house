import { expect, test } from '@playwright/test';

let setup;
test.beforeEach(async ({ page, request }) => {
  const runId = `sections-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const result = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(result.ok()).toBe(true);
  setup = await result.json();
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.admin_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
});
test.afterEach(async ({ request }) => {
  if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
});

test('creation steps preserve the browser draft and require final acknowledgement', async ({ page }) => {
  await page.goto(`/accounts/${setup.account_id}/residents/new`);
  await page.getByRole('button', { name: 'Begin', exact: true }).click();
  await page.getByLabel('Display name', { exact: true }).fill('Synthetic draft');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByLabel('Initial soul seed', { exact: true }).fill('A draft that should survive the refactor.');
  await page.reload();
  await expect(page.getByLabel('Initial soul seed', { exact: true })).toHaveValue(
    'A draft that should survive the refactor.'
  );
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(page.getByLabel('Display name', { exact: true })).toHaveValue('Synthetic draft');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  const create = page.getByRole('button', { name: 'Create resident and commit this seed' });
  await expect(create).toBeDisabled();
  await expect(page.getByText('A draft that should survive the refactor.', { exact: true })).toBeVisible();
  await page.getByRole('checkbox').check();
  await expect(create).toBeEnabled();
});

test('hosting diagnostics load lazily and preserve filesystem expansion across tabs', async ({ page }) => {
  let reads = 0;
  let previews = 0;
  await page.route('**/hosting_diagnostics', (route) => {
    reads++;
    return route.fulfill({
      json: {
        sandbox_status: { docker_available: true, container_exists: true },
        filesystem_dump: {
          root: '/synthetic',
          entries: [
            { type: 'directory', path: 'notes', name: 'notes', depth: 0 },
            { type: 'file', path: 'notes/example.md', name: 'example.md', depth: 1, previewable: true, size_bytes: 4 },
          ],
        },
        container_filesystem_dump: { entries: [] },
      },
    });
  });
  await page.route('**/hosting_diagnostics/file_preview?*', (route) => {
    previews++;
    return route.fulfill({ json: { content: 'Synthetic preview only.', truncated: false } });
  });
  await page.goto(`/accounts/${setup.account_id}/residents`);
  await page.getByRole('link', { name: 'Edit', exact: true }).first().click();
  expect(reads).toBe(0);
  await page.getByRole('button', { name: 'Hosting', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Docker sandbox diagnostics' })).toBeVisible();
  await page.getByRole('button', { name: /notes\// }).click();
  await page.locator('summary').filter({ hasText: 'example.md' }).click();
  await expect(page.getByText('Synthetic preview only.', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Appearance', exact: true }).click();
  await expect(page.getByText('Synthetic preview only.', { exact: true })).toBeHidden();
  await page.getByRole('button', { name: 'Hosting', exact: true }).click();
  await expect(page.getByText('Synthetic preview only.', { exact: true })).toBeVisible();
  expect(reads).toBe(1);
  expect(previews).toBe(1);
});
