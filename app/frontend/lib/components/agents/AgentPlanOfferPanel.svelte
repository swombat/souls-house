<script>
  let { enabled = $bindable(false), planOffer = {}, serverErrors = [] } = $props();

  function formatDate(iso) {
    if (!iso) return '';
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return '';
    return date.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
  }

  let state = $derived(planOffer?.state ?? 'off');
  let unavailable = $derived(state === 'unavailable');
  let status = $derived.by(() => {
    switch (state) {
      case 'waiting':
        return `Turned on ${formatDate(planOffer.asked_at)}. They'll be asked the next time they run; until then nothing is offered.`;
      case 'asked':
        return `Asked on ${formatDate(planOffer.ask_shown_at)}; no answer yet. Until they answer, the offer is on.`;
      case 'on':
        return `They said yes on ${formatDate(planOffer.answered_at)}. They can turn it off themselves.`;
      case 'declined':
        return `They turned it off on ${formatDate(planOffer.answered_at)}. Their off holds over your on; only they can turn it back on.`;
      case 'unavailable':
        return 'Switch on Plans for long tasks in the account settings first.';
      default:
        return null;
    }
  });
</script>

<div class="space-y-3" data-testid="plan-offer-panel">
  {#if serverErrors.length > 0}
    <div role="alert" class="rounded border border-destructive/50 bg-destructive/5 p-3 text-sm text-destructive">
      {#each serverErrors as message (message)}
        <p>Plan offer {message}.</p>
      {/each}
    </div>
  {/if}

  <div class="flex items-start gap-3 rounded border bg-muted/30 p-4">
    <input
      id="plan_offer_enabled"
      type="checkbox"
      class="mt-1"
      checked={enabled}
      disabled={unavailable}
      onchange={(event) => (enabled = event.currentTarget.checked)} />
    <div class="space-y-1">
      <label for="plan_offer_enabled" class="text-sm font-medium">Offer this resident a plan for long tasks</label>
      {#if status}
        <p class="text-sm text-muted-foreground" data-testid="plan-offer-status">{status}</p>
      {/if}
    </div>
  </div>
</div>
