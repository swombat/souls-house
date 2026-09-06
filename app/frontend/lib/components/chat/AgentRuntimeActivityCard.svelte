<script>
  import { onMount } from 'svelte';
  import { formatTime } from '$lib/utils';

  let { interaction } = $props();
  let expanded = $state(Boolean(interaction.active));
  let wasActive = $state(Boolean(interaction.active));
  let now = $state(Date.now());
  const isActive = $derived(Boolean(interaction.active));
  const snapshot = $derived(interaction.snapshot || {});
  const operations = $derived(Object.values(snapshot.operations || {}));
  const duration = $derived(
    isActive && interaction.started_at
      ? Math.max(0, now - new Date(interaction.started_at).getTime())
      : interaction.duration_ms
  );
  const healthStale = $derived(
    isActive &&
      (interaction.reporter_health === 'stale' ||
        (interaction.last_report_at && now - new Date(interaction.last_report_at).getTime() > 30000))
  );

  $effect(() => {
    if (wasActive && !isActive) expanded = false;
    wasActive = isActive;
  });

  onMount(() => {
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  function eventLabel(event) {
    if (event.data?.label) return `${event.data.label}${event.data.outcome ? ` · ${event.data.outcome}` : ''}`;
    return {
      'attempt.started': 'Runtime started',
      'turn.started': 'Work started',
      'turn.finished': 'Turn finished; runtime may still be closing',
      fallback: 'Starting a fresh attempt',
      'supervisor.finished': 'Runtime finished',
      warning: 'Activity detail unavailable',
    }[event.type];
  }
</script>

<div class="flex justify-start" data-testid="runtime-activity-card" data-run-id={interaction.run_id || interaction.id}>
  <details
    bind:open={expanded}
    class="w-full max-w-[90%] md:max-w-[75%] rounded-lg border border-dashed border-muted-foreground/30 bg-muted/20">
    <summary class="cursor-pointer px-4 py-3 text-sm select-none">
      <span class="font-medium">{interaction.agent_name}</span>
      <span class="text-muted-foreground"> {interaction.status_label}</span>
      {#if duration != null}
        <span class="text-xs text-muted-foreground"> · {Math.round(duration / 1000)}s</span>
      {/if}
      {#if !isActive && interaction.reply_label}
        <span class="text-xs text-muted-foreground"> · {interaction.reply_label}</span>
      {/if}
      {#if healthStale}
        <span class="text-xs text-amber-700 dark:text-amber-400"> · Live updates interrupted</span>
      {/if}
    </summary>
    <div class="border-t px-4 py-3 space-y-3 text-sm">
      <p class="text-xs text-muted-foreground">Runtime activity, not a chat reply. Click the summary to minimise.</p>
      {#if !interaction.run_id}
        <p class="text-xs text-muted-foreground">Live activity is unavailable for this older runtime invocation.</p>
      {:else if interaction.reporter_health === 'connecting' && isActive}
        <p class="text-xs text-muted-foreground">Waiting for runtime activity reports.</p>
      {/if}
      {#if interaction.status === 'outcome_unknown'}
        <p class="text-amber-700 dark:text-amber-400">
          Contact was lost. Execution was not confirmed stopped; check before requesting the same work again.
        </p>
      {/if}
      {#if operations.length && isActive}
        <ul class="space-y-1">
          {#each operations as operation}
            <li class="break-words">{operation.label}…</li>
          {/each}
        </ul>
      {/if}
      {#if snapshot.commentary}
        <p class="whitespace-pre-wrap">{snapshot.commentary}</p>
      {:else if snapshot.narration_capability === 'unsupported'}
        <p class="text-xs text-muted-foreground">Narration isn't available from this provider connection.</p>
      {:else if interaction.narration_shared === false}
        <p class="text-xs text-muted-foreground">Working narration isn't shared.</p>
      {:else if interaction.run_id}
        <p class="text-xs text-muted-foreground">No shared working narration received.</p>
      {/if}
      {#if snapshot.plan?.length}
        <ol class="space-y-1">
          {#each snapshot.plan as step}
            <li><span class="text-muted-foreground">{step.status} · </span>{step.text}</li>
          {/each}
        </ol>
      {/if}
      <ol class="space-y-1 text-xs text-muted-foreground" aria-label="Work so far">
        {#each interaction.events || [] as event (event.id)}
          {#if event.type === 'commentary.completed' && event.data?.text}
            <li class="whitespace-pre-wrap">{event.data.text}</li>
          {:else if eventLabel(event)}
            <li class="break-words">{eventLabel(event)}</li>
          {/if}
        {/each}
      </ol>
      {#if interaction.detail_dropped}
        <p class="text-xs text-muted-foreground">Some activity detail was omitted to keep this history bounded.</p>
      {/if}
      {#if interaction.history_truncated}
        <p class="text-xs text-muted-foreground">Showing the most recent 100 stored activity events.</p>
      {/if}
      <p class="text-xs text-muted-foreground">{formatTime(interaction.created_at)}</p>
    </div>
  </details>
</div>
