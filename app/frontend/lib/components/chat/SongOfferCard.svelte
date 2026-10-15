<script>
  import { untrack } from 'svelte';
  import { embedUrl } from '$lib/field-songs';
  import SongCardPlayer from './SongCardPlayer.svelte';

  let { accountId, offer } = $props();
  const identity = $derived(JSON.stringify([accountId, offer.url, offer.title, offer.artist]));
  let result = $state(null);
  let playback = $state(null);
  let pending = $state(null);
  let saveError = $state(null);
  let controller;

  const current = $derived(result?.identity === identity ? result : null);
  const busy = $derived(pending === identity);
  const activeKey = $derived(playback?.identity === identity ? playback.key : null);
  // Only the server-approved link is ever exposed, even for an existing song.
  // An outside offer never includes stored audio or lyrics.
  const display = $derived(
    current?.link ? { title: offer.title || current.song?.title || 'Title needed', links: [current.link] } : null
  );

  async function request(expected, save = false) {
    controller?.abort();
    const requestController = new AbortController();
    controller = requestController;
    pending = expected;
    saveError = null;
    const endpoint = `/accounts/${encodeURIComponent(accountId)}/field/songs/offer`;
    try {
      const response = await fetch(save ? endpoint : `${endpoint}?${new URLSearchParams({ url: offer.url })}`, {
        method: save ? 'POST' : 'GET',
        headers: {
          Accept: 'application/json',
          ...(save
            ? {
                'Content-Type': 'application/json',
                'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
              }
            : {}),
        },
        ...(save ? { body: JSON.stringify({ url: offer.url, title: offer.title, artist: offer.artist }) } : {}),
        cache: 'no-store',
        signal: requestController.signal,
      });
      if (!response.ok) throw new Error('Unavailable');
      const data = await response.json();
      if (!data.link || typeof data.link.url !== 'string' || (save && !data.song?.id)) {
        throw new Error('Unavailable');
      }
      if (requestController.signal.aborted || expected !== identity) return null;
      result = { identity: expected, link: data.link, song: data.song };
      return data;
    } catch {
      if (requestController.signal.aborted || expected !== identity) return null;
      playback = null;
      if (save) saveError = { identity: expected };
      else result = { identity: expected, failed: true };
      return null;
    } finally {
      if (!requestController.signal.aborted && expected === identity) pending = null;
    }
  }

  $effect(() => {
    const expected = identity;
    untrack(() => {
      result = null;
      playback = null;
      saveError = null;
      if (accountId && offer.url) request(expected);
    });
    return () => controller?.abort();
  });

  async function play() {
    const expected = identity;
    playback = null;
    const fresh = await request(expected);
    if (fresh && expected === identity && embedUrl(fresh.link)) {
      playback = { identity: expected, key: 'link-0' };
    }
  }
</script>

<article
  class="not-prose my-3 rounded-lg border border-border bg-background/70 p-3 space-y-3"
  data-testid="song-offer-card">
  <div>
    <p class="font-medium break-words">{offer.title || current?.song?.title || 'Title needed'}</p>
    {#if offer.artist}<p class="text-sm text-muted-foreground">{offer.artist}</p>{/if}
  </div>
  {#if display}
    <SongCardPlayer song={display} {activeKey} {busy} onplay={play} />
    {#if current.song?.id}
      <a
        class="text-xs text-primary hover:underline"
        href={`/accounts/${encodeURIComponent(accountId)}/field?tab=songs&item=song-${encodeURIComponent(current.song.id)}`}
        target="_blank"
        rel="noopener noreferrer">Open in Field</a>
    {:else if offer.title}
      <button class="text-sm underline" disabled={busy} onclick={() => request(identity, true)}>
        {busy ? 'Checking…' : 'Add to Field'}
      </button>
    {:else}
      <p class="text-xs text-muted-foreground">A title is needed to save this song.</p>
    {/if}
    {#if saveError?.identity === identity}
      <p class="text-sm text-muted-foreground" role="status">Could not save to Field. Try again.</p>
    {/if}
  {:else if current?.failed}
    <p class="text-sm text-muted-foreground" role="status">Song unavailable</p>
    <button class="text-xs underline" disabled={busy} onclick={() => request(identity)}>Retry</button>
  {:else}
    <p class="text-sm text-muted-foreground" role="status">Checking song…</p>
  {/if}
</article>
