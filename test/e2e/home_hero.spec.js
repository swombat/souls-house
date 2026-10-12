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

  // The film autoplays muted; one tap turns the sound on from the top.
  const film = page.getByTestId('hero-film');
  await expect(film).toBeVisible();
  await expect(film).toHaveJSProperty('muted', true);
  const sound = page.getByTestId('hero-film-sound');
  await expect(sound).toHaveText('Tap for sound');
  await sound.click();
  await expect(film).toHaveJSProperty('muted', false);
  await expect(sound).toHaveText('Sound off');

  expect(errors).toEqual([]);
});
