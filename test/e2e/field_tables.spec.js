import { expect, test } from '@playwright/test';

// Field tables, end to end: make a table from the Field, give it columns,
// add, edit and delete a row in the grid, and look at it on a phone.
test('a member makes a table, adds a column, and adds, edits and deletes a row', async ({
  page,
  request,
}, testInfo) => {
  const runId = `tables-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const shot = (name) => page.screenshot({ path: testInfo.outputPath(`${name}.png`), fullPage: true });

  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.primary_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in|sign in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);

  const base = `/accounts/${setup.account_param}`;
  await page.goto(`${base}/field`);
  await page.getByTestId('field-tables-link').click();
  await expect(page.getByRole('heading', { name: 'Tables' })).toBeVisible();

  await page.getByLabel('New table name').fill('Build in public posts');
  await page.getByRole('button', { name: 'Make table' }).click();
  await expect(page.getByRole('heading', { name: /Build in public posts/ })).toBeVisible();
  await expect(page.getByTestId('row-count')).toContainText('0 of 1000 rows');

  await page.getByLabel('New column label').fill('Views');
  await page.getByLabel('New column type').selectOption('number');
  await page.getByRole('button', { name: 'Add column' }).click();
  await expect(page.locator('thead')).toContainText('Views');

  await page.getByRole('button', { name: 'Add row' }).first().click();
  await page.locator('input[name="name"]').fill('First post');
  await page.locator('input[name="views"]').fill('12');
  await page.getByRole('button', { name: 'Add row' }).last().click();
  await expect(page.getByRole('cell', { name: 'First post' })).toBeVisible();
  await expect(page.getByRole('cell', { name: '12', exact: true })).toBeVisible();
  await expect(page.getByTestId('row-count')).toContainText('1 of 1000 rows');

  await page.getByRole('button', { name: 'Edit row' }).click();
  await page.locator('input[name="views"]').fill('40');
  await page.getByRole('button', { name: 'Save row' }).click();
  await expect(page.getByRole('cell', { name: '40', exact: true })).toBeVisible();
  await shot('table-desktop');

  // Clearing a number clears the cell (an empty number box must not be dropped).
  await page.getByRole('button', { name: 'Edit row' }).click();
  await page.locator('input[name="views"]').fill('');
  await page.getByRole('button', { name: 'Save row' }).click();
  await expect(page.getByRole('button', { name: 'Save row' })).toHaveCount(0);
  await expect(page.getByRole('cell', { name: '40', exact: true })).toHaveCount(0);
  await expect(page.getByRole('cell', { name: 'First post' })).toBeVisible();

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole('cell', { name: 'First post' })).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  await shot('table-phone');

  page.once('dialog', (dialog) => dialog.accept());
  await page.getByRole('button', { name: 'Delete row' }).click();
  await expect(page.getByText('No rows yet.')).toBeVisible();
  await expect(page.getByTestId('row-count')).toContainText('0 of 1000 rows');
});
