<script>
  import { onMount } from 'svelte';
  import MemoryActivityChart from './MemoryActivityChart.svelte';

  let { overviewUrl, historyUrl = null } = $props();
  const kinds = [
    { key: 'journals', label: 'Journals' },
    { key: 'day_summaries', label: 'Day summaries' },
    { key: 'week_summaries', label: 'Week summaries' },
    { key: 'month_summaries', label: 'Month summaries' },
    { key: 'nodes', label: 'Nodes' },
  ];
  let selected = $state(kinds.map((kind) => kind.key));
  let overview = $state(null);
  let overviewError = $state(null);
  let history = $state(null);
  let historyError = $state(null);
  let loading = $state(false);
  let cursors = $state([null]);
  let page = $state(0);
  let controller;
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

  async function loadHistory(targetPage = 0, cursor = null) {
    if (!historyUrl) return;
    controller?.abort();
    const request = new AbortController();
    controller = request;
    loading = true;
    historyError = null;
    // Never leave old-filter contents visible under newly checked labels.
    history = null;
    const query = new URLSearchParams({ kinds: selected.join(',') });
    if (cursor) query.set('cursor', cursor);
    try {
      const data = await getJson(`${historyUrl}?${query}`, request.signal);
      if (request.signal.aborted) return;
      history = data;
      page = targetPage;
      cursors = [...cursors.slice(0, targetPage), cursor];
    } catch (error) {
      if (error.name !== 'AbortError') historyError = error.message;
    } finally {
      if (controller === request) loading = false;
    }
  }

  function toggle(key, checked) {
    selected = checked ? [...selected, key] : selected.filter((kind) => kind !== key);
    cursors = [null];
    page = 0;
    loadHistory();
  }

  onMount(() => {
    loadOverview();
    loadHistory();
    return () => {
      controller?.abort();
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
    <section class="space-y-4" aria-label="Memory history">
      <div>
        <h3 class="text-lg font-semibold">Memory history</h3>
        <p class="text-sm text-muted-foreground">
          Site admins only · 50 items per page, newest first. Nodes use creation time; journals use dated headings
          (local time as written), summaries use the period they describe. Files do not retain per-entry insertion
          times.
        </p>
      </div>
      <fieldset class="flex flex-wrap gap-4">
        <legend class="mb-2 text-sm font-medium">Include</legend>
        {#each kinds as kind}<label class="flex items-center gap-2 text-sm"
            ><input
              type="checkbox"
              checked={selected.includes(kind.key)}
              onchange={(event) => toggle(kind.key, event.currentTarget.checked)} />{kind.label}</label
          >{/each}
      </fieldset>
      {#if loading}<p role="status">Loading memory history…</p>{/if}
      {#if historyError}<p role="alert">{historyError}</p>
        <button type="button" class="underline" onclick={() => loadHistory()}>Retry from newest</button>{/if}
      {#if history}
        {#if ['unavailable', 'partial'].includes(history.archive_status)}<p
            role="status"
            class="text-sm text-amber-700 dark:text-amber-400">
            Journal archive {history.archive_status}; this list may be incomplete. Available graph nodes are still
            shown.
          </p>{/if}
        {#if history.items.length === 0}<p class="text-sm text-muted-foreground">
            {selected.length ? 'No matching memory items.' : 'Select at least one item type.'}
          </p>{/if}
        <ol class="space-y-4">
          {#each history.items as item (item.id)}
            <li class="rounded-lg border p-4 space-y-3 break-words">
              <div class="text-xs text-muted-foreground">
                {kinds.find((kind) => kind.key === item.kind)?.label} · {item.occurred_at
                  .slice(0, 16)
                  .replace('T', ' ')} · {item.timestamp_basis}
              </div>
              <h4 class="font-medium">{item.title}</h4>
              {#if item.kind === 'nodes'}
                <div class="text-xs text-muted-foreground">
                  {item.node.node_type} · {item.node.is_dormant ? 'Dormant' : 'Active'} · Charge {item.node.charge}
                </div>
                {#if item.node.description}<p class="whitespace-pre-wrap">{item.node.description}</p>{/if}
                <div class="text-sm">
                  <h5 class="font-medium">Pointers</h5>
                  {#if item.node.source_uris?.length}<ul>
                      {#each item.node.source_uris as pointer}<li class="font-mono text-xs break-all">
                          {pointer}
                        </li>{/each}
                    </ul>{:else}<p class="text-muted-foreground">No source pointer</p>{/if}
                </div>
                <details class="text-sm">
                  <summary class="cursor-pointer">Connections ({item.edge_count})</summary>
                  <ul class="space-y-2 mt-2">
                    {#each item.edges as edge}<li>
                        <span>{edge.source.content}</span> <span class="font-medium">→ {edge.edge_type} →</span>
                        <span>{edge.target.content}</span><span class="text-xs text-muted-foreground">
                          (weight {edge.weight})</span>
                      </li>{/each}
                  </ul>
                  {#if item.edges_truncated}<p>Showing the newest 200 connections.</p>{/if}
                </details>
              {:else}
                <p class="font-mono text-xs text-muted-foreground">memory/{item.path}</p>
                {#if item.body}<pre class="whitespace-pre-wrap break-words font-sans text-sm">{item.body}</pre>{/if}
                {#if item.body_status !== 'complete'}<p class="text-sm text-amber-700 dark:text-amber-400">
                    {item.body_status === 'changed'
                      ? 'File changed since measurement. Reopen this tab after two minutes to refresh.'
                      : item.body_status === 'truncated'
                        ? 'Entry exceeds the display limit; showing the first 64 KiB.'
                        : 'Entry contents are unavailable.'}
                  </p>{/if}
              {/if}
            </li>
          {/each}
        </ol>
        <nav class="flex items-center gap-4 text-sm" aria-label="Memory history pages">
          <button
            type="button"
            class="underline disabled:opacity-40"
            disabled={page === 0 || loading}
            onclick={() => loadHistory(page - 1, cursors[page - 1])}>Newer</button>
          <span>Page {page + 1}</span>
          <button
            type="button"
            class="underline disabled:opacity-40"
            disabled={!history.next_cursor || loading}
            onclick={() => loadHistory(page + 1, history.next_cursor)}>Older</button>
        </nav>
      {/if}
    </section>
  {/if}
</div>
