import { test } from '@playwright/experimental-ct-svelte';
import DashboardClip from './DashboardClip.svelte';
import { renderClip } from './render.js';

// Clips made for announcements rather than the features page. They render to
// tmp/announcements/, which is not committed: attach the MP4 where it's posted.
const clips = [['dashboard', DashboardClip, 16]];

for (const [name, Component, duration] of clips) {
  test(name, async ({ mount, page }) => {
    await renderClip({ mount, page, Component, name, duration, outDir: 'tmp/announcements' });
  });
}
