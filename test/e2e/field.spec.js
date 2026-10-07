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

    // A rejected note keeps the dialog open and what was typed.
    await page.getByTestId('field-new-note').click();
    await page.getByLabel('Name').fill('E2E Whiteboard');
    await page.getByLabel(/^Note/).fill('Typed before the clash');
    await page.getByRole('button', { name: 'Create note' }).click();
    await expect(page.getByRole('dialog').getByRole('alert')).toContainText('Name has already been taken');
    await expect(page.getByLabel(/^Note/)).toHaveValue('Typed before the clash');
    await shot('4a-duplicate-note');
    await page.getByLabel('Name').fill('Things to return to');
    await page.getByLabel(/^Note/).fill('# Sunday\n\nThe meeting on Tuesday.');
    await page.getByRole('button', { name: 'Create note' }).click();
    await expect(page).toHaveURL(/item=note-/);
    await expect(page.getByRole('heading', { name: 'Things to return to' })).toHaveCount(2);
    await expect(page.getByText('The meeting on Tuesday.')).toBeVisible();
    await shot('4-note');

    // Editing in place keeps the old text: History lists it and reads it back.
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.getByPlaceholder(/Write your whiteboard content/).fill('# Sunday\n\nThe meeting moved to Wednesday.');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.getByText('The meeting moved to Wednesday.')).toBeVisible();
    await page.getByTestId('note-history-open').click();
    const history = page.getByTestId('note-history');
    await expect(history.getByTestId('note-version')).toHaveCount(1);
    await expect(history.getByTestId('note-version').first()).toContainText(/Replaced .* by /);
    await shot('4b-note-history');
    await history.getByTestId('note-version').first().click();
    await expect(history.getByTestId('note-version-content')).toContainText('The meeting on Tuesday.');
    await shot('4c-note-past-version');
    await page.keyboard.press('Escape');
    await expect(history).toHaveCount(0);

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
