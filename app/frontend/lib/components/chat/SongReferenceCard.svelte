<script>
  import { untrack } from 'svelte';
  import { embedUrl, embedHeight, stanzas } from '$lib/field-songs';

  let { accountId, songId } = $props();
  const identity = $derived(`${accountId}/${songId}`);
  let result = $state(null);
  let playback = $state(null);
  let expanded = $state(false);
  let busy = $state(false);
  let controller;

  // Hide old account data immediately, before the next effect runs.
  const song = $derived(result?.identity === identity ? result.song : null);
  const unavailable = $derived(result?.identity === identity && result.failed);
  const sources = $derived(
    song
      ? [
          ...(song.audio ? [{ key: 'file', label: 'File' }] : []),
          ...(song.links || [])
            .map((link, index) => ({ key: `link-${index}`, label: link.label, link, embed: embedUrl(link) }))
            .filter((source) => source.embed),
        ]
      : []
  );
  const active = $derived(
    song && playback?.identity === identity ? sources.find((source) => source.key === playback.key) : null
  );

  async function load(expected) {
    controller?.abort();
    const request = new AbortController();
    controller = request;
    busy = true;
    try {
      const response = await fetch(
        `/accounts/${encodeURIComponent(accountId)}/field/songs/${encodeURIComponent(songId)}`,
        { headers: { Accept: 'application/json' }, cache: 'no-store', signal: request.signal }
      );
      if (!response.ok) throw new Error('Unavailable');
      const data = await response.json();
      if (!data.song || typeof data.song.title !== 'string') throw new Error('Unavailable');
      if (request.signal.aborted || expected !== identity) return null;
      result = { identity: expected, song: data.song, failed: false };
      return data.song;
    } catch {
      if (request.signal.aborted || expected !== identity) return null;
      result = { identity: expected, song: null, failed: true };
      playback = null;
      return null;
    } finally {
      if (!request.signal.aborted && expected === identity) busy = false;
    }
  }

  $effect(() => {
    const expected = identity;
    // Only a changed account/song identity should reset interaction state.
    // Reading the snippet's props inside load would also subscribe this effect
    // to fresh serialized paragraph props during an Inertia refresh.
    untrack(() => {
      result = null;
      playback = null;
      expanded = false;
      if (accountId && songId) load(expected);
    });
    return () => controller?.abort();
  });

  async function play(key = null) {
    const expected = identity;
    playback = null;
    // A song may have been discarded since this message was opened.
    const fresh = await load(expected);
    if (!fresh || expected !== identity) return;
    const first = fresh.audio ? 'file' : sources[0]?.key;
    playback = { identity: expected, key: key || first };
  }
</script>

<article class="not-prose my-3 rounded-lg border border-border bg-background/70 p-3 space-y-3" data-testid="song-card">
  {#if song}
    <div>
      <p class="font-medium break-words">{song.title}</p>
      {#if song.artist}<p class="text-sm text-muted-foreground">{song.artist}</p>{/if}
      <a
        class="text-xs text-primary hover:underline"
        href={`/accounts/${encodeURIComponent(accountId)}/field?tab=songs&item=song-${encodeURIComponent(songId)}`}
        target="_blank"
        rel="noopener noreferrer">Open in Field</a>
    </div>
    {#if sources.length}
      {#if !active}
        <button class="text-sm underline" disabled={busy} onclick={() => play()}>
          {busy ? 'Checking…' : 'Play'}
        </button>
      {:else}
        {#if sources.length > 1}
          <div class="flex flex-wrap gap-3" aria-label="Listen on">
            {#each sources as source (source.key)}
              <button
                class="text-sm underline"
                aria-pressed={active.key === source.key}
                disabled={busy}
                onclick={() => play(source.key)}>{source.label}</button>
            {/each}
          </div>
        {/if}
        {#if active.key === 'file'}
          <audio controls preload="none" src={song.audio.url} class="w-full"></audio>
        {:else}
          <iframe
            title={`${song.title} on ${active.label}`}
            src={active.embed}
            height={embedHeight(active.link) || 240}
            class="w-full rounded-md border-0"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen></iframe>
        {/if}
      {/if}
    {/if}
    {#if song.links?.length}
      <div class="flex flex-wrap gap-3 text-xs">
        {#each song.links as link}
          <a href={link.url} target="_blank" rel="noopener noreferrer" class="underline">Open on {link.label}</a>
        {/each}
      </div>
    {/if}
    {#if song.lyrics_state === 'present'}
      <button class="text-sm underline" aria-expanded={expanded} onclick={() => (expanded = !expanded)}>
        {expanded ? 'Hide lyrics' : 'Show lyrics'}
      </button>
      {#if expanded}
        <div class="max-w-prose space-y-3 text-sm" data-testid="song-card-lyrics">
          {#each stanzas(song.lyrics) as stanza}
            <p class="whitespace-pre-line break-words">{stanza.join('\n')}</p>
          {/each}
        </div>
      {/if}
    {:else}
      <p class="text-xs text-muted-foreground">
        {song.lyrics_state === 'instrumental' ? 'Instrumental, no lyrics.' : 'No lyrics yet'}
      </p>
    {/if}
  {:else if unavailable}
    <p class="text-sm text-muted-foreground" role="status">Song unavailable</p>
    <button class="text-xs underline" disabled={busy} onclick={() => load(identity)}>Retry</button>
  {:else}
    <p class="text-sm text-muted-foreground" role="status">Loading song…</p>
  {/if}
</article>
