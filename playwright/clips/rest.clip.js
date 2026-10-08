import { test } from '@playwright/experimental-ct-svelte';
import GuestsClip from './GuestsClip.svelte';
import BackupsClip from './BackupsClip.svelte';
import PortabilityClip from './PortabilityClip.svelte';
import TheirWordsClip from './TheirWordsClip.svelte';
import ModelsClip from './ModelsClip.svelte';
import SubscriptionsClip from './SubscriptionsClip.svelte';
import GoogleClip from './GoogleClip.svelte';
import GithubClip from './GithubClip.svelte';
import GithubResidentClip from './GithubResidentClip.svelte';
import TailscaleClip from './TailscaleClip.svelte';
import OpenSourceClip from './OpenSourceClip.svelte';
import { renderClip } from './render.js';

const clips = [
  ['guests', GuestsClip, 16],
  ['backups', BackupsClip, 16],
  ['portability', PortabilityClip, 16],
  ['their-words', TheirWordsClip, 16],
  ['models', ModelsClip, 16],
  ['subscriptions', SubscriptionsClip, 15],
  ['google', GoogleClip, 15],
  ['github', GithubClip, 16],
  ['github-resident', GithubResidentClip, 16],
  ['tailscale', TailscaleClip, 16],
  ['open-source', OpenSourceClip, 16],
];

for (const [name, Component, duration] of clips) {
  test(name, async ({ mount, page }) => {
    await renderClip({ mount, page, Component, name, duration });
  });
}
