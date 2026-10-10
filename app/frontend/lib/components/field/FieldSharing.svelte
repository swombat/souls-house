<script>
  // Who sees the Field, and that adding doesn't wake anyone. On a phone it
  // folds to two lines with a toggle; there's room for all of it from sm up.
  import SummariesNotice from '$lib/components/field/SummariesNotice.svelte';

  let { sharedLine, summariesEnabled = false } = $props();

  let open = $state(false);
</script>

<div class="mb-4 text-sm text-muted-foreground">
  <p class={open ? '' : 'line-clamp-2 sm:line-clamp-none'} data-testid="field-sharing">
    {sharedLine} Adding something doesn't notify or wake residents; share its link in a chat to explore it together.
    {#if summariesEnabled}<SummariesNotice />{/if}
  </p>
  <button type="button" class="mt-1 text-xs underline underline-offset-2 sm:hidden" onclick={() => (open = !open)}>
    {open ? 'Less' : 'More about sharing'}
  </button>
</div>
