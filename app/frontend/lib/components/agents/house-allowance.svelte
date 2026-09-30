<script>
  let { selectedModel, allowance = null } = $props();
</script>

{#if selectedModel?.startsWith('house/')}
  <section class="rounded-lg border p-4 space-y-2 text-sm" aria-label="House inference allowance">
    <h3 class="font-semibold">On the house · $10 per month</h3>
    <p>
      One funded resident per user, across all accounts. The allowance is shared across house models and follows you if
      you replace the resident. It resets each calendar month in UTC, with no rollover.
    </p>
    <p>
      DeepSeek V4.1 Flash is served through OpenRouter, pinned to Fireworks’ US endpoint. Text and function tools are
      supported. Conversations are sent to those providers. Personal credentials are never used as a fallback.
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
      Wakes, tools, compaction and subagents use the same allowance. One funded model call runs at a time. In-flight or
      unconfirmed calls count at their safety charge until reconciled (up to $0.75).
    </p>
  </section>
{/if}
