import { test } from '@playwright/experimental-ct-svelte';
import TelegramClip from './TelegramClip.svelte';
import RhythmsClip from './RhythmsClip.svelte';
import RoomsClip from './RoomsClip.svelte';
import RecallClip from './RecallClip.svelte';
import { renderClip } from './render.js';

const clips = [
  ['telegram', TelegramClip, 16],
  ['rhythms', RhythmsClip, 15],
  ['rooms', RoomsClip, 15],
  ['recall', RecallClip, 16],
];

for (const [name, Component, duration] of clips) {
  test(name, async ({ mount, page }) => {
    await renderClip({ mount, page, Component, name, duration });
  });
}
