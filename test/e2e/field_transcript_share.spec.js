import { expect, test } from '@playwright/test';

// Share on a transcript: copy it, make a link, open the link signed out, and
// revoke it. The fixture is a supplied transcript, so nothing remote runs.
test('a member shares a transcript by link and revokes it', async ({ page, browser, request }, testInfo) => {
  const runId = `field-share-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const shot = (target, name) => target.screenshot({ path: testInfo.outputPath(`${name}.png`), fullPage: true });
  let stranger;

  try {
    const fixture = await request.post('/test/e2e/field_recording_fixture', {
      data: { account_id: setup.account_id, title: 'Shared standup', speakers_ready: true },
    });
    expect(fixture.ok()).toBe(true);
    const { recording_param: recordingParam } = await fixture.json();

    await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);

    await page.goto(`/accounts/${setup.account_param}/field/recordings/${recordingParam}`);
    await page.getByTestId('share-transcript').click();
    const menu = page.getByTestId('share-transcript-menu');
    await expect(menu).toBeVisible();
    await expect(menu.getByTestId('share-expiry-1d')).toHaveAttribute('aria-checked', 'true');

    await menu.getByTestId('copy-transcript').click();
    await expect(menu.getByTestId('copy-transcript')).toContainText('Copied');
    const copied = await page.evaluate(() => navigator.clipboard.readText());
    expect(copied).toContain("A local speaker's first words.");
    expect(copied).toContain('Another local speaker replies.');

    await menu.getByTestId('share-expiry-1w').click();
    await menu.getByTestId('create-share-link').click();
    const url = await menu.getByTestId('share-url').inputValue();
    expect(url).toMatch(/\/shared\/transcripts\/sht_/);
    await expect(menu.getByTestId('share-created')).toContainText('Expires in 7 days');
    await expect(menu.getByTestId('share-list')).toContainText('Not opened yet');
    await shot(page, '1-share-menu');

    // Someone with no account opens the link.
    stranger = await browser.newContext();
    const outside = await stranger.newPage();
    await outside.goto(url);
    await expect(outside.getByTestId('shared-transcript-title')).toHaveText('Shared standup');
    await expect(outside.getByTestId('shared-transcript-lines')).toContainText("A local speaker's first words.");
    await expect(outside.getByTestId('copy-shared-transcript')).toBeVisible();
    await expect(outside.getByTestId('recording-audio')).toHaveCount(0);
    await shot(outside, '2-shared-page');

    // Revoked, the link shows nothing.
    page.once('dialog', (dialog) => dialog.accept());
    await page.keyboard.press('Escape');
    await page.getByTestId('share-transcript').click();
    await expect(menu.getByTestId('share-list')).toContainText('Opened once');
    await menu.getByTestId('revoke-share').click();
    await expect(page.getByTestId('revoke-share')).toHaveCount(0);
    await outside.reload();
    await expect(outside.getByTestId('shared-transcript-unavailable')).toBeVisible();
    await expect(outside.getByTestId('shared-transcript-lines')).toHaveCount(0);
  } finally {
    await stranger?.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
