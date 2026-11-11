<script>
  // What the wizard's Create button says: the step a paid resident is at
  // (starting, off to Stripe, being added to the bill, paying, being made),
  // or what pressing it will do.
  import { Check } from 'phosphor-svelte';
  import { usd } from '$lib/pricing';

  let { processing = false, phase = null, billing = null, chosenTier = null, free = false, name = '' } = $props();
</script>

{#if processing}
  Preparing…
{:else if phase === 'starting'}
  Starting…
{:else if phase === 'leaving'}
  Opening Stripe…
{:else if phase === 'adding'}
  Adding to the bill…
{:else if phase === 'paying'}
  Confirming payment…
{:else if phase === 'confirming'}
  Preparing {name}…
{:else if billing && chosenTier && free}
  <Check class="mr-2 size-4" />
  Start free
{:else if billing && chosenTier}
  <Check class="mr-2 size-4" />
  Create {name} · {usd(chosenTier.monthly_usd)} a month + VAT
{:else}
  <Check class="mr-2 size-4" />
  Create resident and commit this seed
{/if}
