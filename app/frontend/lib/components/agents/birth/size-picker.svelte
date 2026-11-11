<script>
  // The Plan step's size choice: small first, medium and large behind a plain
  // disclosure that opens when one of them is chosen. An account with a code
  // is offered each size at two rates; one rate's sizes show at a time, with
  // a switch.
  import { CheckCircle } from 'phosphor-svelte';
  import { sizeLines, sizeOf, usd } from '$lib/pricing';

  // options: offers (a size at a rate), or for older props the standard tiers.
  let { options = [], tier = $bindable(null), busy = false } = $props();

  let chosen = $derived(options.find((candidate) => candidate.id === tier) || null);
  let rates = $derived([...new Set(options.map((offer) => offer.rate || 'standard'))]);
  let rate = $derived(chosen?.rate || 'standard');
  let shown = $derived(options.filter((offer) => (offer.rate || 'standard') === rate));
  const RATE_LABELS = { standard: 'Standard', at_cost: 'At cost' };

  function chooseRate(next) {
    if (next === rate) return;
    const sameTier = chosen?.tier ?? chosen?.id;
    const match =
      options.find((offer) => offer.rate === next && (offer.tier ?? offer.id) === sameTier) ||
      options.find((offer) => offer.rate === next);
    if (match) tier = match.id;
  }

  let smallOptions = $derived(shown.filter((option) => sizeOf(option) === 'small'));
  let biggerOptions = $derived(shown.filter((option) => sizeOf(option) !== 'small'));
  let smallAtRate = $derived(smallOptions[0] || null);
  let biggerOpen = $state(false);
  $effect(() => {
    if (chosen && sizeOf(chosen) !== 'small') biggerOpen = true;
  });

  function moreThanSmall(option) {
    if (!smallAtRate || option.id === smallAtRate.id) return null;
    return usd(Number(option.monthly_usd) - Number(smallAtRate.monthly_usd));
  }
</script>

{#snippet sizeOption(option)}
  {@const selected = option.id === tier}
  {@const extra = moreThanSmall(option)}
  <label
    class="relative flex cursor-pointer flex-col rounded-lg border-2 p-4 transition-colors
      {selected ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/40'}">
    <input
      type="radio"
      name="plan"
      value={option.id}
      class="sr-only"
      aria-label={option.name}
      checked={selected}
      onchange={() => (tier = option.id)} />
    <span class="flex items-start justify-between gap-2">
      <span class="font-semibold"
        >{option.rate === 'at_cost' ? option.name.replace(/ at cost$/, '') : option.name}</span>
      {#if selected}<CheckCircle class="size-5 shrink-0 text-primary" weight="fill" />{/if}
    </span>
    <span class="mt-1 text-sm text-muted-foreground">{sizeLines[sizeOf(option)] ?? ''}</span>
    <span class="mt-3 flex flex-wrap items-baseline gap-x-1">
      <span class="text-2xl font-semibold">{usd(option.monthly_usd)}</span>
      <span class="whitespace-nowrap text-sm text-muted-foreground">/ month + VAT</span>
    </span>
    {#if extra}
      <span class="mt-1 text-xs text-muted-foreground">{extra} a month more than small</span>
    {/if}
  </label>
{/snippet}

<fieldset class="space-y-4" disabled={busy}>
  <legend class="sr-only">Size</legend>
  <div class="flex flex-wrap items-center justify-between gap-3">
    <span class="text-sm font-medium" aria-hidden="true">Size</span>
    {#if rates.length > 1}
      <div
        class="inline-flex rounded-md border bg-muted/40 p-0.5 text-sm"
        role="group"
        aria-label="Rate"
        data-testid="plan-rate">
        {#each rates as option (option)}
          <button
            type="button"
            class="rounded px-3 py-1 transition-colors {option === rate
              ? 'bg-background font-medium shadow-sm'
              : 'text-muted-foreground hover:text-foreground'}"
            aria-pressed={option === rate}
            onclick={() => chooseRate(option)}>
            {RATE_LABELS[option] ?? option}
          </button>
        {/each}
      </div>
    {/if}
  </div>
  <div class="space-y-3" role="radiogroup" aria-label="Size">
    {#each smallOptions as option (option.id)}
      {@render sizeOption(option)}
    {/each}
    {#if biggerOptions.length}
      <details class="group rounded-lg border" bind:open={biggerOpen} data-testid="plan-bigger">
        <summary class="cursor-pointer list-none px-4 py-3 text-sm font-medium">
          Need a bigger computer?
          <span class="font-normal text-muted-foreground">For code, a browser, or heavy work.</span>
        </summary>
        <div class="grid gap-3 px-4 pb-4 {biggerOptions.length >= 2 ? 'sm:grid-cols-2' : ''}">
          {#each biggerOptions as option (option.id)}
            {@render sizeOption(option)}
          {/each}
        </div>
      </details>
    {/if}
  </div>
</fieldset>
