import { expect, test } from '@playwright/test';

test('a member brings a file into the Field, writes a note, and deletes the file', async ({
  page,
  request,
}, testInfo) => {
  const runId = `field-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const shot = (name) => page.screenshot({ path: testInfo.outputPath(`${name}.png`), fullPage: true });

  try {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);

    const base = `/accounts/${setup.account_param}`;
    await page.goto(`${base}/chats`);
    await page.getByRole('link', { name: 'Field', exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(`${base}/field$`));
    await expect(page.getByRole('heading', { name: 'Field', exact: true })).toBeVisible();
    await expect(page.getByTestId('field-sharing')).toContainText('Shared with every human member and resident in');
    await expect(page.getByText('E2E Whiteboard').first()).toBeVisible();
    await shot('1-field-with-a-note');

    // The old whiteboards page now lands on the Notes tab.
    await page.goto(`${base}/whiteboards`);
    await expect(page).toHaveURL(/tab=notes/);
    await expect(page.getByRole('tab', { name: /Notes/ })).toHaveAttribute('aria-selected', 'true');

    await page.getByTestId('field-add-file').click();
    await expect(page.getByRole('dialog')).toContainText('Shared with every human member and resident');
    await page.getByLabel(/^File/).setInputFiles({
      name: 'tuesday-meeting.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('Notes from Tuesday.'),
    });
    await page.getByLabel('Title').fill('Tuesday meeting');
    await page.getByLabel(/Why I'm bringing this/).fill("I came away uneasy, but I don't know why.");
    await shot('2-add-file');
    await page.getByRole('button', { name: 'Add to the Field' }).click();

    const viewer = page.getByTestId('field-file-viewer');
    await expect(viewer).toContainText('Tuesday meeting');
    await expect(viewer).toContainText("I came away uneasy, but I don't know why.");
    await expect(viewer).toContainText('tuesday-meeting.txt');
    await expect(viewer.getByRole('link', { name: /Download/ })).toHaveAttribute('href', /disposition=attachment/);
    await expect(page).toHaveURL(/item=file-/);
    await shot('3-file');

    await page.getByTestId('field-new-note').click();
    await page.getByLabel('Name').fill('Things to return to');
    await page.getByLabel(/^Note/).fill('# Sunday\n\nThe meeting on Tuesday.');
    await page.getByRole('button', { name: 'Create note' }).click();
    await expect(page).toHaveURL(/item=note-/);
    await expect(page.getByRole('heading', { name: 'Things to return to' })).toBeVisible();
    await shot('4-note');

    await page.getByRole('tab', { name: /Files/ }).click();
    await page.getByTestId('field-item').filter({ hasText: 'Tuesday meeting' }).click();
    page.once('dialog', (dialog) => dialog.accept());
    await viewer.getByRole('button', { name: /Delete/ }).click();
    await expect(page.getByTestId('field-item').filter({ hasText: 'Tuesday meeting' })).toHaveCount(0);
    await shot('5-after-delete');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
