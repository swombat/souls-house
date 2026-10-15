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
  let undoError = $state(null);
  let undoWindow = $state(null);
  let undoTimer;
  let controller;

  const current = $derived(result?.identity === identity ? result : null);
  const busy = $derived(pending === identity);
  const activeKey = $derived(playback?.identity === identity ? playback.key : null);
  const canUndo = $derived(undoWindow?.identity === identity && undoWindow.songId === current?.song?.id);
  // Only the server-approved link is ever exposed, even for an existing song.
  // An outside offer never includes stored audio or lyrics.
  const display = $derived(
    current?.link ? { title: offer.title || current.song?.title || 'Title needed', links: [current.link] } : null
  );

  function clearUndo() {
    clearTimeout(undoTimer);
    undoWindow = null;
  }

  async function request(expected, action = 'check') {
    const save = action === 'save';
    const discard = action === 'discard';
    if (discard && (!canUndo || Date.now() >= undoWindow.deadline || busy)) {
      if (undoWindow && Date.now() >= undoWindow.deadline) clearUndo();
      return null;
    }
    const songId = current?.song?.id;
    controller?.abort();
    const requestController = new AbortController();
    controller = requestController;
    pending = expected;
    saveError = null;
    undoError = null;
    const endpoint = `/accounts/${encodeURIComponent(accountId)}/field/songs/offer`;
    try {
      const url = discard
        ? `/accounts/${encodeURIComponent(accountId)}/field/songs/${encodeURIComponent(songId)}`
        : save
          ? endpoint
          : `${endpoint}?${new URLSearchParams({ url: offer.url })}`;
      const response = await fetch(url, {
        method: discard ? 'DELETE' : save ? 'POST' : 'GET',
        headers: {
          Accept: 'application/json',
          ...(save || discard
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
      if (discard) {
        if (response.status !== 204) throw new Error('Unavailable');
        if (requestController.signal.aborted || expected !== identity) return null;
        clearUndo();
        result = { identity: expected, link: current.link, song: null };
        return true;
      }
      if (!response.ok) throw new Error('Unavailable');
      const data = await response.json();
      if (!data.link || typeof data.link.url !== 'string' || (save && !data.song?.id)) {
        throw new Error('Unavailable');
      }
      if (requestController.signal.aborted || expected !== identity) return null;
      if (undoWindow && undoWindow.songId !== data.song?.id) clearUndo();
      result = { identity: expected, link: data.link, song: data.song };
      if (save && data.created === true) {
        clearUndo();
        undoWindow = { identity: expected, songId: data.song.id, deadline: Date.now() + 20000 };
        undoTimer = setTimeout(clearUndo, 20000);
      }
      return data;
    } catch {
      if (requestController.signal.aborted || expected !== identity) return null;
      if (discard) undoError = { identity: expected };
      else {
        playback = null;
        if (save) saveError = { identity: expected };
        else result = { identity: expected, failed: true };
      }
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
      undoError = null;
      clearUndo();
      if (accountId && offer.url) request(expected);
    });
    return () => {
      controller?.abort();
      clearTimeout(undoTimer);
    };
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
      {#if canUndo}
        <button class="ml-3 text-sm underline" disabled={busy} onclick={() => request(identity, 'discard')}>
          Undo
        </button>
      {/if}
    {:else if offer.title}
      <button class="text-sm underline" disabled={busy} onclick={() => request(identity, 'save')}>
        {busy ? 'Checking…' : 'Add to Field'}
      </button>
    {:else}
      <p class="text-xs text-muted-foreground">A title is needed to save this song.</p>
    {/if}
    {#if saveError?.identity === identity}
      <p class="text-sm text-muted-foreground" role="status">Could not save to Field. Try again.</p>
    {/if}
    {#if undoError?.identity === identity}
      <p class="text-sm text-muted-foreground" role="status">
        Could not confirm undo.{canUndo ? ' Try again.' : ' Check the Field.'}
      </p>
    {/if}
  {:else if current?.failed}
    <p class="text-sm text-muted-foreground" role="status">Song unavailable</p>
    <button class="text-xs underline" disabled={busy} onclick={() => request(identity)}>Retry</button>
  {:else}
    <p class="text-sm text-muted-foreground" role="status">Checking song…</p>
  {/if}
</article>
