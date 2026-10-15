<script>
  import { songReference, songOffer } from '$lib/song-reference';
  import SongReferenceCard from './SongReferenceCard.svelte';
  import SongOfferCard from './SongOfferCard.svelte';

  let { token, children, accountId } = $props();
  const songId = $derived(songReference(token));
  const offer = $derived(songOffer(token));
</script>

{#if songId}
  <SongReferenceCard {accountId} {songId} />
{:else if offer}
  <SongOfferCard {accountId} {offer} />
{:else}
  <p data-streamdown-paragraph class="text-foreground">{@render children()}</p>
{/if}
