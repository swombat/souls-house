import { test } from '@playwright/experimental-ct-svelte';
import JournalsClip from './JournalsClip.svelte';
import HeartbeatsClip from './HeartbeatsClip.svelte';
import ComputerClip from './ComputerClip.svelte';
import AttachmentsClip from './AttachmentsClip.svelte';
import StonesClip from './StonesClip.svelte';
import DashboardClip from './DashboardClip.svelte';
import { renderClip } from './render.js';

const clips = [
  ['journals', JournalsClip, 16],
  ['heartbeats', HeartbeatsClip, 16],
  ['computer', ComputerClip, 16],
  ['attachments', AttachmentsClip, 15],
  ['stones', StonesClip, 16],
  ['dashboard', DashboardClip, 16],
];

for (const [name, Component, duration] of clips) {
  test(name, async ({ mount, page }) => {
    await renderClip({ mount, page, Component, name, duration });
  });
}
