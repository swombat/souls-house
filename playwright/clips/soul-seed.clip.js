import { test } from '@playwright/experimental-ct-svelte';
import SoulSeedClip from './SoulSeedClip.svelte';
import { renderClip } from './render.js';

test('soul-seed', async ({ mount, page }) => {
  await renderClip({ mount, page, Component: SoulSeedClip, name: 'soul-seed', duration: 15 });
});
