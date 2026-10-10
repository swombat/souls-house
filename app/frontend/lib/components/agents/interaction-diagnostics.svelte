<script>
  import RuntimeOutput from './RuntimeOutput.svelte';
  let { interaction } = $props();
  function bytes(value) {
    if (value === null || value === undefined) return 'unknown';
    if (value < 1024) return `${value} B`;
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
    return `${(value / 1024 / 1024).toFixed(1)} MiB`;
  }
</script>

<details class="mt-4 rounded border bg-muted/30 text-sm">
  <summary class="cursor-pointer px-3 py-2 font-medium">Session diagnostics and output</summary>
  <div class="space-y-3 border-t p-3">
    <div class="grid gap-2 text-xs sm:grid-cols-2 lg:grid-cols-3">
      <div>
        <span class="text-muted-foreground">Logical session:</span>
        <span class="font-mono">{interaction.session_id || 'unknown'}</span>
      </div>
      <div>
        <span class="text-muted-foreground">Chaos process:</span>
        <span class="font-mono">{interaction.chaos_session_id || 'unknown'}</span>
      </div>
      <div>
        <span class="text-muted-foreground">Transport/runtime:</span>
        {interaction.transport_status ?? 'n/a'} / {interaction.runtime_status || 'n/a'} /
        {interaction.runtime_returncode ?? 'n/a'}
      </div>
      <div>
        <span class="text-muted-foreground">Lifecycle:</span>
        {interaction.session_outcome || 'unknown'}
        {#if interaction.session_roll_reason}
          · {interaction.session_roll_reason}{/if}
      </div>
      <div>
        <span class="text-muted-foreground">Prompt:</span>
        {interaction.prompt_mode || 'unknown'} · selected {bytes(interaction.selected_prompt_bytes)}
      </div>
      <div>
        <span class="text-muted-foreground">Chaos/cache:</span>
        {interaction.chaos_version || 'unknown'} / {interaction.cache_ttl || 'unknown'}
      </div>
    </div>

    {#if Object.keys(interaction.prompt_component_bytes || {}).length}
      <div class="text-xs text-muted-foreground">
        Prompt components:
        {Object.entries(interaction.prompt_component_bytes)
          .map(([key, value]) => `${key} ${bytes(value)}`)
          .join(' · ')}
      </div>
    {/if}

    {#if interaction.out_of_memory_message}
      <div class="rounded border border-destructive/30 bg-destructive/10 p-2 text-xs text-destructive">
        {interaction.out_of_memory_message}
      </div>
    {/if}

    {#if interaction.error_message}
      <div class="rounded border border-destructive/30 bg-destructive/10 p-2 text-xs text-destructive">
        {interaction.error_class}: {interaction.error_message}
      </div>
    {/if}

    <RuntimeOutput {interaction} />
  </div>
</details>
