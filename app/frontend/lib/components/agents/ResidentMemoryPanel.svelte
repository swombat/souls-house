<script>
  import ResidentMemoryHistory from './resident-memory-history.svelte';
  import { onMount } from 'svelte';
  import MemoryActivityChart from './MemoryActivityChart.svelte';

  let { overviewUrl, historyUrl = null } = $props();
  let overview = $state(null);
  let overviewError = $state(null);
  let summaryController;

  async function getJson(url, signal) {
    const response = await fetch(url, { signal, headers: { Accept: 'application/json' } });
    if (!response.ok)
      throw new Error(response.status === 403 ? 'Access denied.' : 'Could not load memory. Please retry.');
    return response.json();
  }

  async function loadOverview() {
    summaryController?.abort();
    summaryController = new AbortController();
    overviewError = null;
    try {
      overview = await getJson(overviewUrl, summaryController.signal);
    } catch (error) {
      if (error.name !== 'AbortError') overviewError = error.message;
    }
  }

  onMount(() => {
    loadOverview();
    return () => {
      summaryController?.abort();
    };
  });
</script>

<div class="space-y-6">
  <div>
    <h2 class="text-xl font-semibold">Memory</h2>
    <p class="text-sm text-muted-foreground">
      Read-only journal and Mnemodyne state. Inspecting this page does not wake the resident. Journal measurements are
      cached for up to two minutes.
    </p>
  </div>
  {#if overviewError}
    <p role="alert">{overviewError}</p>
    <button type="button" class="underline" onclick={loadOverview}>Retry summary</button>
  {:else if !overview}
    <p role="status">Loading memory summary…</p>
  {:else}
    <dl class="grid grid-cols-3 gap-3">
      <div class="rounded-lg border p-4">
        <dt class="text-sm text-muted-foreground">Journal entries</dt>
        <dd class="text-2xl font-semibold">
          {overview.journals.count?.toLocaleString() ?? '—'}{overview.journals.status === 'partial' ? '+' : ''}
        </dd>
      </div>
      <div class="rounded-lg border p-4">
        <dt class="text-sm text-muted-foreground">Nodes</dt>
        <dd class="text-2xl font-semibold">{overview.node_count.toLocaleString()}</dd>
      </div>
      <div class="rounded-lg border p-4">
        <dt class="text-sm text-muted-foreground">Connections</dt>
        <dd class="text-2xl font-semibold">{overview.edge_count.toLocaleString()}</dd>
      </div>
    </dl>
    {#if overview.journals.status !== 'measured'}
      <p role="status" class="text-sm text-amber-700 dark:text-amber-400">
        Journal archive {overview.journals.status === 'partial'
          ? 'partially read: counts are lower bounds.'
          : 'unavailable: journal counts are unknown, not zero.'}
      </p>
    {/if}
    <div class="grid gap-4 lg:grid-cols-2">
      {#if overview.journals.status !== 'unavailable'}
        <MemoryActivityChart
          title="Journal entries"
          days={overview.days}
          series={[{ key: 'journals', label: 'Entries', colour: 'bg-violet-500' }]} />
      {/if}
      <MemoryActivityChart
        title="Node and connection additions"
        days={overview.days}
        series={[
          { key: 'nodes', label: 'Nodes', colour: 'bg-sky-500' },
          { key: 'edges', label: 'Connections', colour: 'bg-amber-500' },
        ]} />
    </div>
    <p class="text-xs text-muted-foreground">
      Last 14 days, including today. Journals use their file dates; graph additions use creation dates (UTC). Graph
      counts include all node types and dormant nodes, but exclude deleted records.
    </p>
  {/if}

  {#if historyUrl}
    <ResidentMemoryHistory {historyUrl} />
  {/if}
</div>
