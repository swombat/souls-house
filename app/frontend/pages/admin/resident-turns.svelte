<script>
  import { router } from '@inertiajs/svelte';
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/shadcn/button';

  let { enabled, limit, counts, turns } = $props();
  let desiredLimit = $state(limit);
  onMount(() => {
    const timer = setInterval(() => router.reload({ preserveScroll: true }), 10_000);
    return () => clearInterval(timer);
  });
</script>

<svelte:head><title>Resident concurrency</title></svelte:head>

<div class="mx-auto max-w-6xl space-y-6 p-6">
  <h1 class="text-2xl font-semibold">Resident concurrency</h1>
  <p>Asynchronous admission is {enabled ? 'enabled' : 'disabled (legacy synchronous dispatch)'}.</p>
  <p>
    {counts.queued || 0} queued · {counts.starting || 0} starting · {counts.running || 0} running ·
    {counts.unknown || 0} uncertain. Starting and uncertain turns occupy capacity.
  </p>
  <form
    class="flex items-center gap-3"
    onsubmit={(event) => {
      event.preventDefault();
      router.patch('/admin/resident_turns/capacity', { limit: desiredLimit });
    }}>
    <label for="capacity">Turn limit (0 pauses admission)</label>
    <input id="capacity" type="number" min="0" max="1000" bind:value={desiredLimit} class="w-24 rounded border p-2" />
    <Button type="submit">Save</Button>
  </form>
  <p class="text-sm text-muted-foreground">
    Lowering the limit never kills an existing turn. Unknown outcomes require verified runtime containment; a timeout
    alone never releases their slots. This limit does not bound builds, browsers or subagents.
  </p>
  <div class="overflow-x-auto">
    <table class="w-full text-left text-sm">
      <thead
        ><tr><th>Resident</th><th>Kind</th><th>State</th><th>Queued</th><th>Last checked</th><th>Control</th></tr
        ></thead>
      <tbody>
        {#each turns as turn (turn.id)}
          <tr class="border-t">
            <td class="py-3">{turn.resident}</td>
            <td>{turn.kind}</td>
            <td>
              {turn.state}{turn.cancel_requested ? ' — cancellation requested' : ''}
              {#if turn.diagnostic}<p class="text-muted-foreground">{turn.diagnostic}</p>{/if}
            </td>
            <td>{new Date(turn.queued_at).toLocaleString()}</td>
            <td>{turn.checked_at ? new Date(turn.checked_at).toLocaleString() : 'not yet'}</td>
            <td>
              <Button
                variant="outline"
                disabled={turn.cancel_requested}
                onclick={() => router.delete(`/admin/resident_turns/${turn.id}`, { preserveScroll: true })}>
                Cancel
              </Button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
  <p class="text-sm text-muted-foreground">Showing the oldest 200 unfinished turns.</p>
</div>
