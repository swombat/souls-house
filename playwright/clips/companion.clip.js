import { test } from '@playwright/experimental-ct-svelte';
import Clip from './CompanionClip.svelte';
import { renderClip } from './render.js';

test('companion', async ({ mount, page }) => {
  await renderClip({ mount, page, Component: Clip, name: 'companion', duration: 14 });
});
