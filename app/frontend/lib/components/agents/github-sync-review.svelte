<script>
  let { request } = $props();
  let standard = $derived(request.sync_strategy === 'standard');
  let policies = $derived([
    ['Eligible auto-commit paths', request.sync_auto_commit_paths || []],
    ['Protected paths', request.sync_protected_paths || request.sync_auto_commit_paths || []],
    ['Append-only paths', request.sync_append_only_paths || []],
    ['Destructive-change allowances', request.sync_allow_destructive_paths || []],
  ]);
</script>

<section class="space-y-3 rounded-lg border p-5" aria-label="Reviewed home sync policy">
  <h2 class="text-lg font-semibold">Reviewed home sync policy</h2>
  <p class="text-sm font-medium">{standard ? 'Use standard two-way Git sync' : 'Keep existing sync'}</p>
  {#if standard}
    <p class="text-sm text-muted-foreground">
      These literal file or directory scopes come from the reviewed manifest, not a browser setting. Only eligible paths
      may be automatically committed; this is not permission to save every edit.
    </p>
    {#each policies as [label, paths]}
      <div class="space-y-1 text-sm">
        <h3 class="font-medium">{label}</h3>
        {#if paths.length}
          <ul class="list-inside list-disc">
            {#each paths as path}
              <li class="break-all"><code>{path}</code></li>
            {/each}
          </ul>
        {:else}
          <p class="text-muted-foreground">
            {label === 'Eligible auto-commit paths'
              ? 'None — committed changes only. Uncommitted edits are not automatically saved.'
              : 'None declared.'}
          </p>
        {/if}
      </div>
    {/each}
    <p class="text-sm text-muted-foreground">
      Protected paths refuse deletion or shrink below {Math.round((request.sync_shrink_minimum_ratio ?? 0.5) * 100)}% of
      their HEAD byte size unless explicitly allowed above. Append-only paths always refuse rewriting or truncation,
      even with a destructive allowance.
    </p>
    <p class="text-sm text-muted-foreground">
      Append-only merging applies only to proven complete UTF-8 line additions: it preserves common-base lines,
      deduplicates new lines and sorts additions by UTF-8 bytes. Other conflicts require manual reconciliation; neither
      identity anchors nor narratives are automatically reconciled.
    </p>
  {:else}
    <p class="text-sm text-muted-foreground">
      The home's existing sync script remains responsible for its own policy. Existing residents are not enrolled or
      reconfigured by this choice.
    </p>
  {/if}
</section>
