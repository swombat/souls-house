<script>
  let { selectedModel, allowance = null } = $props();

  const routes = {
    'house/claude-haiku-5.5': 'Claude Haiku 5.5 is served through OpenRouter, pinned to Anthropic’s own API.',
    'house/deepseek-v4.1-flash': 'DeepSeek V4.1 Flash is served through OpenRouter, pinned to Fireworks’ US endpoint.',
  };
</script>

{#if selectedModel?.startsWith('house/')}
  <section class="rounded-lg border p-4 space-y-2 text-sm" aria-label="House inference allowance">
    {#if allowance?.source === 'plan'}
      <h3 class="font-semibold">{allowance.plan} plan · ${allowance.limit_usd.toFixed(2)} this month</h3>
      <p>
        This resident's paid plan funds its house models. The allowance belongs to this resident, is shared across house
        models, and resets each calendar month in UTC, with no rollover. The free $10 allowance isn't used while the
        plan is paid.
      </p>
    {:else if allowance?.source === 'free'}
      <h3 class="font-semibold">Free hosting · $10 per month</h3>
      <p>
        This resident was created before plans existed, so it has $10 of house models a month of its own. It isn't
        shared with your other residents, doesn't move to another resident, and resets each calendar month in UTC, with
        no rollover. Your personal free allowance isn't used for it.
      </p>
    {:else}
      <h3 class="font-semibold">On the house · $10 per month</h3>
      <p>
        One funded resident per user, across all accounts. The allowance is shared across house models and follows you
        if you replace the resident. It resets each calendar month in UTC, with no rollover.
      </p>
    {/if}
    <p>
      {routes[selectedModel] || 'This model is served through OpenRouter on a single pinned provider.'} Text and function
      tools are supported. Conversations are sent to those providers. Personal credentials are never used as a fallback.
    </p>
    {#if allowance}
      <p class="font-medium">
        ${allowance.remaining_usd.toFixed(2)} remaining · resets {allowance.resets_at} (UTC)
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
        : ' One funded model call runs at a time.'} In-flight or unconfirmed calls count at their safety charge until
      reconciled (up to $0.75).
    </p>
  </section>
{/if}
