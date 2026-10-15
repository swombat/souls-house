<script>
  import { songReference } from '$lib/song-reference';
  import SongReferenceCard from './SongReferenceCard.svelte';

  let { token, children, accountId } = $props();
  const songId = $derived(songReference(token));
</script>

{#if songId}
  <SongReferenceCard {accountId} {songId} />
{:else}
  <p data-streamdown-paragraph class="text-foreground">{@render children()}</p>
{/if}
