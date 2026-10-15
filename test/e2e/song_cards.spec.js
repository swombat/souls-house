import { expect, test } from '@playwright/test';

test('a resident offers a song in-place, with no external player before a click', async ({
  page,
  request,
}, testInfo) => {
  const runId = `song-card-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const players = [];
  await page.route(/youtube-nocookie\.com|open\.spotify\.com\/embed/, (route) => {
    players.push(route.request().url());
    return route.fulfill({ status: 200, contentType: 'text/html', body: '<p>Synthetic player</p>' });
  });

  try {
    const fixtureResponse = await request.post('/test/e2e/song_card_fixture', {
      data: { account_id: setup.account_id },
    });
    expect(fixtureResponse.ok()).toBe(true);
    const fixture = await fixtureResponse.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(fixture.chat_url);

    const card = page.getByTestId('song-card').filter({ hasText: 'Hallelujah' });
    await expect(card).toBeVisible();
    await expect(card).toContainText('Jeff Buckley');
    await expect(page.getByText('Song unavailable', { exact: true })).toBeVisible();
    await expect(page.getByText('Discarded secret')).toHaveCount(0);
    await expect(page.locator('iframe')).toHaveCount(0);
    await expect(page.locator('audio')).toHaveCount(0);
    expect(players).toEqual([]);
    await expect(page.locator('code').filter({ hasText: '[[song:' })).toHaveCount(3);
    await card.getByRole('button', { name: 'Show lyrics', exact: true }).click();
    await expect(card).toContainText('A secret chord');
    const refresh = page.waitForResponse(
      (response) => response.url().endsWith(fixture.chat_url) && response.request().headers()['x-inertia'] === 'true'
    );
    const update = await page.request.patch(fixture.chat_url, {
      data: { chat: { title: 'Song card refreshed' } },
      maxRedirects: 0,
    });
    expect(update.status()).toBe(302);
    await refresh;
    await expect(page.getByRole('heading', { name: 'Song card refreshed', exact: true })).toBeVisible();
    await expect(card.getByRole('button', { name: 'Hide lyrics', exact: true })).toBeVisible();
    expect(players).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath('song-card-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: testInfo.outputPath('song-card-mobile.png'), fullPage: true });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await card.getByRole('button', { name: /play/i }).click();
    await expect(card.locator('iframe')).toHaveAttribute('src', /youtube-nocookie\.com\/embed\/y8AWFf7EAc4/);
    await expect.poll(() => players.length).toBe(1);

    // The message contains a reference, not a historical copy of discarded data.
    const deletion = await page.request.delete(fixture.song_url, { maxRedirects: 0 });
    expect(deletion.status()).toBe(302);
    await page.reload();
    await expect(page.getByText('Song unavailable', { exact: true })).toHaveCount(2);
    await expect(page.getByText('Hallelujah', { exact: true })).toHaveCount(0);
    await expect(page.locator('iframe')).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
