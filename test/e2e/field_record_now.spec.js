import { expect, test } from '@playwright/test';

// Record now: a voice note spoken straight into the Field, with Chromium's fake
// microphone. The take goes through the same direct upload and recordings POST
// as a file brought in, so it lands as a recording item.

test.use({
  permissions: ['microphone'],
  launchOptions: { args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] },
});

let setup;

test.beforeEach(async ({ page, request }) => {
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `field-record-now-${Date.now()}-${Math.random().toString(36).slice(2)}` },
  });
  expect(response.ok()).toBe(true);
  setup = await response.json();
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.primary_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in|sign in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
});

test.afterEach(async ({ request }) => {
  if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
});

test('Add → Record now records at once, and Save to Field brings the take in as a recording', async ({
  page,
}, testInfo) => {
  const dialogs = [];
  page.on('dialog', (dialog) => {
    dialogs.push(dialog.message());
    dialog.accept();
  });
  await page.setViewportSize({ width: 1280, height: 900 });
  const base = `/accounts/${setup.account_param}`;
  await page.goto(`${base}/field`);

  await page.getByTestId('field-add').click();
  const items = page.getByRole('menuitem');
  await expect(items.first()).toContainText('Record now');
  await expect(items.nth(1)).toContainText('Bring in a recording');
  await page.screenshot({ path: testInfo.outputPath('1-add-menu.png') });
  await page.getByTestId('field-record-now').click();

  const timer = page.getByTestId('voice-note-timer');
  await expect(timer).toBeVisible();
  await expect(timer).not.toHaveText('0:00', { timeout: 5000 });
  // Escape doesn't throw a live take away.
  await page.keyboard.press('Escape');
  await expect(timer).toBeVisible();
  await page.getByTestId('voice-note-stop').click();

  await expect(page.getByTestId('voice-note-playback')).toBeVisible();
  const title = page.getByLabel('Title');
  await expect(title).toHaveValue(/^Voice note · /);
  await title.fill('Record now e2e');
  await page.screenshot({ path: testInfo.outputPath('2-review.png') });
  await page.getByTestId('voice-note-save').click();

  await expect(page).toHaveURL(/item=recording-/, { timeout: 15000 });
  await expect(page.getByTestId('voice-note-dialog')).toBeHidden();
  await expect(page.getByText('Record now e2e').first()).toBeVisible();
  // Our own save is not a page leave: nothing asked "discard?".
  expect(dialogs).toEqual([]);
});

test('on a phone, Add opens a sheet with Record now first, and Tables stays beside the items', async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const base = `/accounts/${setup.account_param}`;
  await page.goto(`${base}/field`);
  await expect(page.getByTestId('field-tables-link')).toBeInViewport();
  await page.getByTestId('field-add').click();
  const sheet = page.getByTestId('field-add-sheet');
  await expect(sheet).toBeVisible();
  await expect(sheet.getByRole('button').first()).toContainText('Record now');
  // The whole list fits: the last choice is on screen once the sheet has slid up.
  await expect(sheet.getByTestId('field-add-song')).toBeInViewport({ ratio: 1 });
  // Keyboard focus moves into the sheet, onto the first choice.
  await expect(sheet.getByTestId('field-record-now')).toBeFocused();
  await page.screenshot({ path: testInfo.outputPath('3-phone-sheet.png') });
  await sheet.getByTestId('field-record-now').click();
  await expect(page.getByTestId('voice-note-timer')).toBeVisible();
  await page.getByTestId('voice-note-stop').click();
  await expect(page.getByTestId('voice-note-playback')).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath('4-phone-review.png') });
});
