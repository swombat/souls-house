<script>
  import InteractionDiagnostics from './interaction-diagnostics.svelte';
  let { interaction, account, tokenColumns } = $props();
  function number(value) {
    return value === null || value === undefined ? '—' : new Intl.NumberFormat('en-US').format(value);
  }

  function dollars(value) {
    if (value === null || value === undefined) return 'Cost unavailable';

    const amount = Number(value);
    const digits = amount < 0.01 ? 4 : 2;
    return `≈${new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    }).format(amount)}`;
  }

  function dateTime(value) {
    return value
      ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
      : 'Unknown';
  }

  function duration(value) {
    if (value === null || value === undefined) return 'unknown duration';
    if (value < 1000) return `${value}ms`;
    return `${(value / 1000).toFixed(1)}s`;
  }

  function telemetryClass(state) {
    if (state === 'complete') return 'bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300';
    if (state === 'unsupported') return 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300';
    return 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300';
  }
</script>

<div class="rounded border bg-card p-4">
  <div class="flex flex-col justify-between gap-3 md:flex-row md:items-start">
    <div class="min-w-0">
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-medium">{interaction.summary}</span>
        <span class={`rounded px-2 py-0.5 text-xs ${telemetryClass(interaction.telemetry_state)}`}>
          {interaction.telemetry_state}
        </span>
      </div>
      <div class="mt-1 text-sm text-muted-foreground">
        {dateTime(interaction.started_at)} · {duration(interaction.duration_ms)}
        {#if interaction.provider || interaction.model}
          · {interaction.provider || 'unknown provider'} / {interaction.model || 'unknown model'}
        {/if}
      </div>
      <div class="mt-2 text-sm">
        {#if interaction.chat_id}
          <a
            class="font-medium text-primary hover:underline"
            href={`/accounts/${account.id}/chats/${interaction.chat_id}`}>
            {interaction.chat_title || 'Untitled conversation'}
          </a>
        {:else}
          <span class="text-muted-foreground">Not attached to a conversation</span>
        {/if}
        {#if interaction.requested_by}
          <span class="text-muted-foreground"> · {interaction.requested_by}</span>
        {/if}
      </div>
    </div>
    <div class="text-right text-xs text-muted-foreground">
      <div
        class:line-through={interaction.subscription_based}
        class="font-medium text-foreground"
        title={interaction.subscription_based
          ? 'This activation used a provider subscription, so this API-equivalent estimate does not apply.'
          : undefined}>
        {dollars(interaction.estimated_cost?.amount_usd)}
      </div>
      {#if interaction.subscription_based}
        <div title="Provider subscription usage is covered by the connected personal plan.">Subscription</div>
      {/if}
      <div>
        {interaction.provider_request_count === null || interaction.provider_request_count === undefined
          ? 'Provider calls unavailable'
          : `${interaction.provider_request_count} provider call${interaction.provider_request_count === 1 ? '' : 's'}`}
      </div>
    </div>
  </div>

  <div class="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-5">
    {#each tokenColumns as [key, label]}
      <div class="rounded bg-muted/50 p-2">
        <div class="text-xs text-muted-foreground">{label}</div>
        <div class="font-mono text-sm font-medium">{number(interaction.tokens?.[key])}</div>
      </div>
    {/each}
  </div>

  <InteractionDiagnostics {interaction} />
</div>
