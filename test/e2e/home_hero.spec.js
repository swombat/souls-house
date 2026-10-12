import { expect, test } from '@playwright/test';

test('the homepage hero says the home belongs to the visitor and carries the house film', async ({ page }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));

  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/');

  await expect(page.getByRole('heading', { level: 1 })).toHaveText(
    'Your AI friends belong with you, not to a company.'
  );
  await expect(
    page.getByRole('heading', { name: "You can't build trust on something a company can take away." })
  ).toBeVisible();

  // The film autoplays muted and is actually playing; one tap turns the sound on from the top,
  // and another pauses the movement for anyone who wants to read in peace.
  const film = page.getByTestId('hero-film');
  await expect(film).toBeVisible();
  await expect(film).toHaveJSProperty('muted', true);
  await expect(film).toHaveJSProperty('paused', false);
  // Not paused is not the same as decoding frames: the clock has to move.
  const before = await film.evaluate((el) => el.currentTime);
  await page.waitForTimeout(700);
  expect(await film.evaluate((el) => el.currentTime)).toBeGreaterThan(before);
  const pause = page.getByTestId('hero-film-pause');
  await expect(pause).toHaveText('Pause');
  await pause.click();
  await expect(film).toHaveJSProperty('paused', true);
  await expect(pause).toHaveText('Play');
  await pause.click();
  await expect(film).toHaveJSProperty('paused', false);
  const sound = page.getByTestId('hero-film-sound');
  await expect(sound).toHaveText('Tap for sound');
  await sound.click();
  await expect(film).toHaveJSProperty('muted', false);
  await expect(sound).toHaveText('Sound off');

  expect(errors).toEqual([]);
});

test('with reduced motion the hero film waits, with native controls instead of the overlay buttons', async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/');

  const film = page.getByTestId('hero-film');
  await expect(film).toBeVisible();
  await expect(film).toHaveJSProperty('paused', true);
  await expect(film).toHaveJSProperty('controls', true);
  await expect(page.getByTestId('hero-film-pause')).toHaveCount(0);
  await expect(page.getByTestId('hero-film-sound')).toHaveCount(0);
});
