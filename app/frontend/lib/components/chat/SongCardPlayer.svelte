<script>
  import { embedUrl, embedHeight, songProviderLabel } from '$lib/field-songs';

  let { song, activeKey = null, busy = false, onplay } = $props();
  const sources = $derived([
    ...(song.audio ? [{ key: 'file', label: 'File' }] : []),
    ...(song.links || [])
      .map((link, index) => ({ key: `link-${index}`, label: songProviderLabel(link), link, embed: embedUrl(link) }))
      .filter((source) => source.embed),
  ]);
  const active = $derived(sources.find((source) => source.key === activeKey));
</script>

{#if sources.length}
  {#if !active}
    <button class="text-sm underline" disabled={busy} onclick={() => onplay()}>
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
            onclick={() => onplay(source.key)}>{source.label}</button>
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
      <a href={link.url} target="_blank" rel="noopener noreferrer" class="underline">
        Open on {songProviderLabel(link)}
      </a>
    {/each}
  </div>
{/if}
