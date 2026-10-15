import { expect, test } from '@playwright/test';

test('outside offers save only by choice and resolve the saved recording on reload', async ({
  page,
  request,
}, testInfo) => {
  const runId = `outside-song-${Date.now()}`;
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
      data: { account_id: setup.account_id, outside_offers: true },
    });
    expect(fixtureResponse.ok()).toBe(true);
    const fixture = await fixtureResponse.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(fixture.chat_url);

    const offer = page.getByTestId('song-offer-card').first();
    await expect(offer).toContainText('Outside song');
    await expect(offer).toContainText('Example artist');
    await expect(offer.getByRole('button', { name: 'Add to Field', exact: true })).toBeEnabled();
    await expect(offer.getByRole('link', { name: 'Open in Field', exact: true })).toHaveCount(0);
    await expect(offer.getByRole('button', { name: /lyrics/i })).toHaveCount(0);
    const apple = page.getByTestId('song-offer-card').filter({ hasText: 'Apple offer' });
    await expect(apple.getByRole('link', { name: /Open on Apple Music/i })).toHaveAttribute(
      'href',
      'https://music.apple.com/us/album/example/123'
    );
    await expect(apple.getByRole('button', { name: /play/i })).toHaveCount(0);
    await expect(page.getByText('Song unavailable', { exact: true })).toHaveCount(2);
    await expect(page.locator('iframe, audio')).toHaveCount(0);
    expect(players).toEqual([]);

    await offer.getByRole('button', { name: 'Add to Field', exact: true }).click();
    const fieldLink = offer.getByRole('link', { name: 'Open in Field', exact: true });
    await expect(fieldLink).toBeVisible();
    const savedHref = await fieldLink.getAttribute('href');
    await page.reload();
    await expect(offer.getByRole('link', { name: 'Open in Field', exact: true })).toHaveAttribute('href', savedHref);
    await expect(offer.getByRole('button', { name: 'Add to Field', exact: true })).toHaveCount(0);
    await expect(page.locator('iframe, audio')).toHaveCount(0);
    expect(players).toEqual([]);
    await page.screenshot({ path: testInfo.outputPath('outside-song-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.reload();
    await expect(offer).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await offer.screenshot({ path: testInfo.outputPath('outside-song-mobile.png') });
    await offer.getByRole('button', { name: /play/i }).click();
    await expect(offer.locator('iframe')).toHaveAttribute('src', /youtube-nocookie\.com\/embed\/aqz-KE-bpKQ/);
    await expect.poll(() => players.length).toBe(1);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
