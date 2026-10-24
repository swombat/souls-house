<script>
  // An open song: a way to hear it first, then who shared it with whom and
  // why, then the words set as verse. Every link also opens on its own site,
  // because an embed can be blocked (a removed video, a region, a login).
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { ArrowSquareOut, PencilSimple, Trash } from 'phosphor-svelte';
  import { formatWhen } from '$lib/field';
  import { embedHeight, embedUrl, sharedBy, songByline, stanzas } from '$lib/field-songs';

  let { song, onEdit, onDelete } = $props();

  // The sources that can play here: the file first, then each link with an
  // embed. One plays at a time; the others are a switch away.
  const sources = $derived([
    ...(song.audio ? [{ key: 'file', label: 'File' }] : []),
    ...song.links
      .map((link, index) => ({ key: `link-${index}`, label: link.label, link, embed: embedUrl(link) }))
      .filter((s) => s.embed),
  ]);
  let chosen = $state(null);
  const active = $derived(sources.find((s) => s.key === chosen) || sources[0] || null);
  const verse = $derived(stanzas(song.lyrics));
  const when = $derived(formatWhen(song.dated_at || song.created_at));
</script>

<Card.Root data-testid="field-song-viewer">
  <Card.Content class="p-6 space-y-5">
    {#if active}
      <div class="space-y-2">
        {#if sources.length > 1}
          <div class="flex flex-wrap gap-1" role="tablist" aria-label="Listen on">
            {#each sources as source (source.key)}
              <Button
                size="sm"
                variant={active.key === source.key ? 'secondary' : 'ghost'}
                role="tab"
                aria-selected={active.key === source.key}
                onclick={() => (chosen = source.key)}>{source.label}</Button>
            {/each}
          </div>
        {/if}
        {#if active.key === 'file'}
          <audio controls preload="metadata" src={song.audio.url} class="w-full" data-testid="field-song-audio"></audio>
        {:else if active.link.provider === 'spotify'}
          <iframe
            title="{song.title} on Spotify"
            src={active.embed}
            height={embedHeight(active.link)}
            class="w-full rounded-xl border-0"
            loading="lazy"
            allow="autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture"
            data-testid="field-song-embed"></iframe>
        {:else}
          <iframe
            title="{song.title} on YouTube"
            src={active.embed}
            class="aspect-video w-full rounded-md border-0"
            loading="lazy"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen
            data-testid="field-song-embed"></iframe>
        {/if}
      </div>
    {/if}

    {#if song.links.length}
      <div class="flex flex-wrap gap-2" data-testid="field-song-links">
        {#each song.links as link, index (index)}
          <Button href={link.url} target="_blank" rel="noopener noreferrer" variant="outline" size="sm">
            <ArrowSquareOut class="size-4" /> Open on {link.label}
          </Button>
        {/each}
      </div>
    {/if}

    <div>
      <h2 class="text-2xl font-semibold break-words">{song.title}</h2>
      {#if songByline(song)}<p class="text-muted-foreground">{songByline(song)}</p>{/if}
      <p class="text-sm text-muted-foreground mt-1" data-testid="field-song-shared">
        {[sharedBy(song), when].filter(Boolean).join(' · ')}
      </p>
    </div>

    {#if song.note}
      <p class="border-l-2 pl-4 font-sans italic whitespace-pre-line break-words" data-testid="field-song-note">
        {song.note}
      </p>
    {/if}

    {#if song.lyrics_state === 'present'}
      <div class="space-y-4 max-w-prose" data-testid="field-song-lyrics">
        {#each verse as stanza, i (i)}
          <p class="leading-relaxed">
            {#each stanza as line, j (j)}{line}{#if j < stanza.length - 1}<br />{/if}{/each}
          </p>
        {/each}
      </div>
    {:else if song.lyrics_state === 'instrumental'}
      <p class="text-sm text-muted-foreground" data-testid="field-song-instrumental">Instrumental, no lyrics.</p>
    {:else}
      <div class="rounded-md border border-dashed p-4 space-y-2" data-testid="field-song-lyrics-missing">
        <p class="text-sm">The lyrics haven't been added yet.</p>
        <Button size="sm" onclick={() => onEdit({ lyrics: true })}>Add the lyrics</Button>
      </div>
    {/if}

    <div class="flex flex-wrap gap-2 pt-2">
      <Button variant="ghost" size="sm" onclick={() => onEdit({ lyrics: false })} data-testid="field-song-edit">
        <PencilSimple class="size-4" /> Edit
      </Button>
      <Button variant="ghost" size="sm" onclick={onDelete}>
        <Trash class="size-4" /> Delete
      </Button>
    </div>
  </Card.Content>
</Card.Root>
