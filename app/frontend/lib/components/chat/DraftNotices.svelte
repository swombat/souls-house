<script>
  // The composer draft's sync status, a conflict with another client, and any
  // unsynced local copies that can be recovered (MessageComposer).
  let { draftState, onresolve, onrecover } = $props();
</script>

<div
  role="status"
  class={draftState.storageError || draftState.locked || draftState.status.startsWith('Not synced')
    ? 'mt-1 text-xs text-muted-foreground'
    : 'sr-only'}>
  {draftState.status}
  {#if draftState.storageError}
    <span class="text-destructive"> Local recovery unavailable—keep this page open until saved.</span>
  {:else if draftState.localSaved && draftState.status.startsWith('Not synced')}
    <span> Saved on this device.</span>
  {/if}
</div>
{#if draftState.conflict}
  <div class="mt-2 text-sm border border-amber-500 rounded p-2" role="alert">
    <p>Another client changed this draft. Your text is still in the editor.</p>
    <pre class="whitespace-pre-wrap max-h-32 overflow-auto my-2">{draftState.conflict.content || '(Empty draft)'}</pre>
    <button class="underline mr-3" onclick={() => onresolve(true)}>Keep my text</button>
    <button class="underline" onclick={() => onresolve(false)}>Use other draft</button>
  </div>
{/if}
{#each draftState.recoveries as copy (copy.key)}
  {#if copy.content !== draftState.content}
    <details class="mt-2 text-sm">
      <summary>Unsynced local draft available</summary>
      <pre class="whitespace-pre-wrap max-h-32 overflow-auto">{copy.content || '(Empty draft)'}</pre>
      <button class="underline" onclick={() => onrecover(copy)}>Recover this text</button>
    </details>
  {/if}
{/each}
