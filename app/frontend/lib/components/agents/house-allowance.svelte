<script>
  import { page } from '@inertiajs/svelte';
  import { billingNumbers } from '$lib/billing-numbers';

  let { selectedModel, allowance = null } = $props();

  // One allowance, the account's (billing_numbers, Billing::Allowance).
  const numbers = $derived(billingNumbers($page.props));

  // During the account's free trial the allowance is one amount for the whole
  // trial, not a month of it (ResidentEntitlement#allowance_presentation).
  let trialEnd = $derived(
    allowance?.trial_ends_at
      ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(
          new Date(allowance.trial_ends_at)
        )
      : null
  );

  const routes = {
    'house/claude-haiku-5.5': 'Claude Haiku 5.5 is served through OpenRouter, pinned to Anthropic’s own API.',
    'house/deepseek-v4.1-flash': 'DeepSeek V4.1 Flash is served through OpenRouter, pinned to Fireworks’ US endpoint.',
  };
</script>

{#if selectedModel?.startsWith('house/')}
  <section class="rounded-lg border p-4 space-y-2 text-sm" aria-label="House inference allowance">
    {#if allowance?.source === 'plan'}
      <h3 class="font-semibold">
        {allowance.plan} · {trialEnd ? `${numbers.accountAllowance} for the free trial` : `$${allowance.limit_usd.toFixed(2)} this month`}
      </h3>
      <p>
        {#if allowance.rate?.startsWith('at_cost')}
          Paid for at cost, so it includes no house-model use: this resident runs on its own model subscription or key.
        {:else if trialEnd}
          During the free trial the account's house-model allowance is {numbers.accountAllowance} in all until {trialEnd}, not
          {numbers.accountAllowance} a month. It is shared by the account's residents at the standard price and across house
          models. If the resident is kept after the trial, the allowance becomes {numbers.accountAllowance} a month.
        {:else}
          The account gets {numbers.accountAllowance} a month of house-model use, shared by its residents at the standard
          price and across house models. It resets each calendar month in UTC, with no rollover.
        {/if}
      </p>
    {:else if allowance?.source === 'free'}
      <h3 class="font-semibold">Free hosting · the account's {numbers.accountAllowance} a month</h3>
      <p>
        This resident was created before plans existed, so the house hosts it free. Its house-model use comes from the
        account's {numbers.accountAllowance} a month, shared by the account's residents and across house models. It
        resets each calendar month in UTC, with no rollover.
      </p>
    {:else}
      <h3 class="font-semibold">On the house · the account's {numbers.accountAllowance} a month</h3>
      <p>
        One funded resident per person, across all accounts. Its use comes from the account's
        {numbers.accountAllowance} a month, shared by the account's residents and across house models. It resets each
        calendar month in UTC, with no rollover.
      </p>
    {/if}
    <p>
      {routes[selectedModel] || 'This model is served through OpenRouter on a single pinned provider.'} Text and function
      tools are supported. Conversations are sent to those providers. Personal credentials are never used as a fallback.
    </p>
    {#if allowance}
      <p class="font-medium">
        ${allowance.remaining_usd.toFixed(2)} remaining · {trialEnd
          ? `until ${trialEnd}`
          : `resets ${allowance.resets_at} (UTC)`}
      </p>
      {#if !allowance.configured}
        <p class="text-destructive">The operator still needs to configure house inference before this route can run.</p>
      {/if}
    {:else}
      <p>Saving this model selection claims your house allowance. No personal API key is required.</p>
    {/if}
    <p class="text-muted-foreground">
      Wakes, tools, compaction and subagents use the same allowance.{allowance?.source === 'plan' ||
      allowance?.source === 'free'
        ? ' A call starts only if its safety charge fits in what is left.'
        : ' One funded model call runs at a time.'} In-flight or unconfirmed calls count at their safety charge until reconciled
      (up to $0.75).
    </p>
  </section>
{/if}
