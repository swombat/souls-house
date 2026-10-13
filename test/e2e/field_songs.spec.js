import { expect, test } from '@playwright/test';

// Songs in the Field, end to end. The lookups (YouTube oEmbed, LRCLIB) are
// answered in the browser so the test never reaches outside; the players'
// frames are answered with an empty page.
test('a member shares songs: from a link with checked lyrics, an instrumental, and one whose words come later', async ({
  page,
  request,
}, testInfo) => {
  const runId = `songs-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const shot = (name) => page.screenshot({ path: testInfo.outputPath(`${name}.png`), fullPage: true });

  await page.route(/youtube-nocookie\.com|open\.spotify\.com\/embed/, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<html><body>player</body></html>' })
  );
  let lyricsLookup = 'found';
  await page.route(/\/field\/songs\/lookup\?/, (route) => {
    const url = new URL(route.request().url());
    const link = url.searchParams.get('url');
    if (link && !/youtu/.test(link)) {
      return route.fulfill({
        json: {
          suggestion: { link: { provider: 'other', url: link, embed_id: null }, found: false, message: 'Type it in.' },
        },
      });
    }
    if (link) {
      return route.fulfill({
        json: {
          suggestion: {
            link: { provider: 'youtube', url: link, embed_id: 'y8AWFf7EAc4' },
            title: 'Hallelujah',
            artist: 'Jeff Buckley',
            found: true,
            message: null,
          },
        },
      });
    }
    if (lyricsLookup === 'down') return route.fulfill({ status: 502, json: { error: 'Couldn’t reach lrclib.net' } });
    return route.fulfill({
      json: {
        candidates: [
          {
            id: 1,
            title: 'Hallelujah',
            artist: 'Jeff Buckley',
            album: 'Grace',
            duration_s: 413,
            instrumental: false,
            lyrics: "Now I've heard there was a secret chord\nThat David played",
          },
        ],
      },
    });
  });

  try {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}`;
    await page.goto(`${base}/field`);

    // 1. From a link: the title and artist arrive; typed words survive a lookup.
    await page.getByTestId('field-add-song').click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toContainText('Find lyrics sends the title and artist to LRCLIB');
    await page.getByTestId('field-song-link').first().fill('https://youtu.be/y8AWFf7EAc4');
    await page.getByLabel('Title').click();
    await expect(page.getByLabel('Title')).toHaveValue('Hallelujah');
    await expect(page.getByLabel('Artist')).toHaveValue('Jeff Buckley');

    await page.getByTestId('field-song-lyrics').fill('my own transcription');
    await page.getByTestId('field-song-find-lyrics').click();
    const candidate = page.getByTestId('field-song-candidate');
    await expect(candidate).toContainText('Grace');
    await expect(candidate).toContainText('6:53');
    page.once('dialog', (d) => d.dismiss());
    await candidate.getByRole('button', { name: 'Replace with these' }).click();
    await expect(page.getByTestId('field-song-lyrics')).toHaveValue('my own transcription');
    page.once('dialog', (d) => d.accept());
    await candidate.getByRole('button', { name: 'Replace with these' }).click();
    await expect(page.getByTestId('field-song-lyrics')).toHaveValue(
      "Now I've heard there was a secret chord\nThat David played"
    );
    await page.getByLabel(/Why this song/).fill('The version from the kitchen at 2am.');
    await shot('1-share-a-song');
    await page.getByTestId('field-song-save').click();

    const viewer = page.getByTestId('field-song-viewer');
    await expect(page).toHaveURL(/item=song-/);
    await expect(viewer.getByRole('heading', { name: 'Hallelujah' })).toBeVisible();
    await expect(viewer.getByTestId('field-song-lyrics')).toContainText('That David played');
    await expect(viewer.getByTestId('field-song-note')).toContainText('kitchen at 2am');
    await expect(viewer.getByRole('link', { name: 'Open on YouTube' })).toHaveAttribute('href', /youtu\.be/);
    await expect(viewer.getByTestId('field-song-embed')).toHaveAttribute(
      'src',
      /youtube-nocookie\.com\/embed\/y8AWFf7EAc4/
    );
    await shot('2-the-song');

    // 2. The lookup is down: manual entry still works, and an instrumental doesn't wait.
    lyricsLookup = 'down';
    await page.getByTestId('field-add-song').click();
    await page.getByTestId('field-song-link').first().fill('https://open.spotify.com/track/5NGtFXVpXSvwunEIGeviY3');
    await page.getByLabel('Title').fill('Spiegel im Spiegel');
    await page.getByLabel('Artist').fill('Arvo Pärt');
    await page.getByTestId('field-song-find-lyrics').click();
    await expect(page.getByTestId('field-song-lyrics-message')).toContainText('You can paste the lyrics yourself');
    await page.getByTestId('field-song-instrumental').check();
    await page.getByTestId('field-song-save').click();
    await expect(viewer.getByTestId('field-song-instrumental')).toBeVisible();

    // 3. Shared before its words: it waits in Needs you until they're added.
    await page.getByTestId('field-add-song').click();
    await page.getByTestId('field-song-link').first().fill('https://grouper.bandcamp.com/track/heavy-water');
    await page.getByLabel('Title').fill('Heavy Water / I’d Rather Be Sleeping');
    await page.getByTestId('field-song-save').click();
    await expect(viewer.getByTestId('field-song-lyrics-missing')).toBeVisible();
    await expect(viewer.getByRole('link', { name: 'Open on Bandcamp' })).toBeVisible();
    await expect(viewer).not.toContainText('Jeff Buckley');

    await page.getByRole('tab', { name: /Needs you/ }).click();
    await expect(page.getByTestId('field-item')).toHaveCount(1);
    await expect(page.getByTestId('field-item').first()).toContainText('No lyrics yet');
    await shot('3-needs-you');

    await viewer.getByRole('button', { name: 'Add the lyrics' }).click();
    await expect(page.getByTestId('field-song-lyrics')).toBeFocused();
    await page.getByTestId('field-song-lyrics').fill('The words, at last');
    await page.getByTestId('field-song-save').click();
    await expect(viewer.getByTestId('field-song-lyrics')).toContainText('The words, at last');
    await page.getByRole('tab', { name: /Songs/ }).click();
    await expect(page.getByTestId('field-item')).toHaveCount(3);
    await shot('4-songs');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
