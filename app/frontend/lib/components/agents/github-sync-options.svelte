<script>
  let { value = $bindable('existing'), strategies = [], disabled = false, error = null } = $props();
</script>

<fieldset class="space-y-3 rounded-md border p-4" {disabled}>
  <legend class="px-1 text-sm font-medium">Home Git sync</legend>
  {#each strategies as strategy}
    <label class="flex items-start gap-3 text-sm">
      <input type="radio" name="sync-strategy" value={strategy.value} bind:group={value} class="mt-1" />
      <span>{strategy.label}</span>
    </label>
  {/each}
  {#if value === 'standard'}
    <p class="text-sm text-muted-foreground">
      Sync committed changes with the selected origin branch in both directions. GitHub Contents write permission is
      needed to push. Your local working copy needs its own setup; this does not configure or stop your local harness.
    </p>
    <p class="text-sm text-muted-foreground">
      Only paths declared in <code>resident-home.json</code> under <code>standard_sync.auto_commit_paths</code> are eligible
      for automatic commits. An absent or empty list means committed changes only: uncommitted edits are not automatically
      saved. The exact policy is shown for review before approval.
    </p>
    <p class="text-sm text-muted-foreground">
      Conflicts need deliberate reconciliation. Standard sync is not a promise of automatic conflict resolution.
    </p>
  {:else}
    <p class="text-sm text-muted-foreground">
      Keep the manifest's existing Python sync entry point. The house does not replace it with standard sync or
      reconfigure existing residents.
    </p>
  {/if}
  {#if error}
    <p role="alert" class="text-sm text-destructive">{error}</p>
  {/if}
</fieldset>
