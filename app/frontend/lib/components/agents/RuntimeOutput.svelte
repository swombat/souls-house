<script>
  let { interaction } = $props();
</script>

<div class="space-y-3">
  {#if interaction.stdout}
    <div>
      <div class="text-xs font-medium">
        stdout ({interaction.stdout_chars ?? interaction.stdout.length} characters)
        {#if interaction.stdout_may_be_truncated}
          <span class="text-amber-700 dark:text-amber-400">· tail only; earlier output may be missing</span>
        {/if}
      </div>
      <pre
        class="mt-1 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded bg-muted/30 p-3 text-xs">{interaction.stdout}</pre>
    </div>
  {:else}
    <p class="text-sm text-muted-foreground">No stdout was captured for this trigger.</p>
  {/if}

  {#if interaction.stderr}
    <details>
      <summary class="cursor-pointer text-xs font-medium text-destructive">
        stderr ({interaction.stderr_chars ?? interaction.stderr.length} characters)
        {#if interaction.stderr_may_be_truncated}
          <span class="text-amber-700 dark:text-amber-400">· tail only; earlier output may be missing</span>
        {/if}
      </summary>
      <pre
        class="mt-1 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded bg-muted/30 p-3 text-xs">{interaction.stderr}</pre>
    </details>
  {/if}
</div>
