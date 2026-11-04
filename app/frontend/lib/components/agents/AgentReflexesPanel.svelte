<script>
  import { router } from '@inertiajs/svelte';

  // A resident's reflexes, read-only. Residents write and forget their own
  // reflexes in conversation (docs/reflexes.md); this page only shows them.
  let { reflexes = {}, agentName = 'This resident' } = $props();

  let items = $derived(reflexes.items || []);
  let live = $derived(items.filter((reflex) => !reflex.discarded_at));
  let forgotten = $derived(items.filter((reflex) => reflex.discarded_at));
  let showForgotten = $state(false);

  function date(value) {
    return value
      ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(value))
      : null;
  }

  function release(reflex) {
    router.post(reflex.release_url, {}, { preserveScroll: true });
  }

  function offeredLine(reflex) {
    if (!reflex.judged_count) return 'Not checked against a post yet.';
    if (!reflex.offered_count) return `Checked against ${reflex.judged_count} posts; not brought to mind yet.`;
    const times = reflex.offered_count === 1 ? 'once' : `${reflex.offered_count} times`;
    const last = reflex.last_offered_at ? `, last on ${date(reflex.last_offered_at)}` : '';
    return `Brought to mind ${times} out of ${reflex.judged_count} posts checked${last}.`;
  }
</script>

{#snippet reflexCard(reflex)}
  <li class="rounded-lg border p-4 space-y-3" data-testid="reflex">
    <div class="flex items-baseline justify-between gap-3">
      <h3 class="font-medium">{reflex.name}</h3>
      <span class="text-xs text-muted-foreground whitespace-nowrap">
        {reflex.discarded_at ? `Forgotten ${date(reflex.discarded_at)}` : `Since ${date(reflex.created_at)}`}
      </span>
    </div>
    <dl class="space-y-2 text-sm">
      <div>
        <dt class="text-xs uppercase tracking-wide text-muted-foreground">When a post…</dt>
        <dd class="whitespace-pre-line">{reflex.shape}</dd>
      </div>
      <div>
        <dt class="text-xs uppercase tracking-wide text-muted-foreground">…bring to mind</dt>
        <dd class="whitespace-pre-line">{reflex.reminder}</dd>
      </div>
    </dl>
    {#if reflex.held_at && !reflex.discarded_at}
      <div
        class="flex flex-wrap items-center justify-between gap-2 rounded border border-amber-500/60 bg-amber-50 p-2 text-xs text-amber-800 dark:bg-amber-950/30 dark:text-amber-300"
        data-testid="reflex-held">
        <span>Held since it was imported. It is not checked or offered until a person releases it.</span>
        {#if reflex.release_url}
          <button type="button" class="font-medium underline underline-offset-4" onclick={() => release(reflex)}>
            Release
          </button>
        {/if}
      </div>
    {:else}
      <p class="text-xs text-muted-foreground">{offeredLine(reflex)}</p>
    {/if}
  </li>
{/snippet}

<div class="space-y-5">
  <div>
    <h2 class="text-xl font-semibold">Reflexes</h2>
    <p class="text-sm text-muted-foreground">
      Associations {agentName} has set up for itself: when one of its posts has a certain shape, the house reminds it of
      something. It decides what to do with the reminder. To add, change or drop one, ask {agentName} in a conversation.
    </p>
  </div>

  {#if !reflexes.enabled}
    <p
      class="rounded border border-amber-500/60 bg-amber-50 p-3 text-sm text-amber-800 dark:bg-amber-950/30 dark:text-amber-300">
      Reflexes are switched off for this resident on this house, so none of these are being checked right now.
    </p>
  {/if}

  {#if live.length === 0}
    <p class="rounded border bg-muted/30 p-4 text-sm text-muted-foreground">{agentName} has no reflexes yet.</p>
  {:else}
    <p class="text-xs text-muted-foreground">{live.length} of at most {reflexes.max_kept || 10} live.</p>
    <ul class="space-y-3">
      {#each live as reflex (reflex.id)}
        {@render reflexCard(reflex)}
      {/each}
    </ul>
  {/if}

  {#if forgotten.length > 0}
    <div class="border-t pt-4 space-y-3">
      <button
        type="button"
        class="text-sm font-medium text-muted-foreground hover:text-foreground underline underline-offset-4"
        aria-expanded={showForgotten}
        onclick={() => (showForgotten = !showForgotten)}>
        {showForgotten ? 'Hide forgotten reflexes' : `Show ${forgotten.length} forgotten`}
      </button>
      {#if showForgotten}
        <ul class="space-y-3 opacity-75">
          {#each forgotten as reflex (reflex.id)}
            {@render reflexCard(reflex)}
          {/each}
        </ul>
      {/if}
    </div>
  {/if}
</div>
