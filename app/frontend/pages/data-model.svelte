<script>
  import { inertia, router } from '@inertiajs/svelte';

  // Props come from PagesController#data_model: the area list for the selector,
  // the chosen area with its tables and Mermaid source, and the map's location.
  let { areas, area, table_count, map_url } = $props();

  let svg = $state('');
  let diagramError = $state('');
  let rendering = $state(true);

  // Mermaid is loaded only on this page, and only in the browser.
  let mermaidModule;
  async function renderDiagram(source, areaId) {
    rendering = true;
    diagramError = '';
    try {
      mermaidModule ??= (await import('mermaid')).default;
      const dark = document.documentElement.classList.contains('dark');
      mermaidModule.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: dark ? 'dark' : 'neutral',
        maxTextSize: 400000,
        maxEdges: 4000,
        er: { layoutDirection: 'TB', useMaxWidth: true },
      });
      const result = await mermaidModule.render(`data-model-${areaId}-${Date.now()}`, source);
      svg = result.svg;
    } catch (error) {
      svg = '';
      diagramError = error?.message ?? String(error);
    } finally {
      rendering = false;
    }
  }

  $effect(() => {
    const source = area.diagram;
    const id = area.id;
    renderDiagram(source, id);
  });

  function pickArea(event) {
    router.visit(`/data-model/${event.currentTarget.value}`);
  }

  function referenceHref(reference) {
    return reference.area ? `/data-model/${reference.area.id}#${reference.table}` : `#${reference.table}`;
  }

  function areaTitle(id) {
    return areas.find((candidate) => candidate.id === id)?.title ?? id;
  }
</script>

<svelte:head>
  <title>{area.title} — the data model — souls.house</title>
  <meta
    name="description"
    content="The house's database, one concern at a time: the tables, their columns and the keys between them, read from the live schema." />
</svelte:head>

<header class="border-b bg-muted/40">
  <div class="mx-auto max-w-6xl px-6 py-12 lg:px-8">
    <a href="/self-host/technical" class="text-sm underline underline-offset-4">Back to the technical guide</a>
    <h1 class="mt-6 text-4xl font-semibold tracking-tight">The data model.</h1>
    <p class="mt-4 max-w-2xl text-muted-foreground">
      The house's database one concern at a time, for people reading the open source. Pick an area and you get its
      tables, their columns, and the keys between them, read from the schema this house is running.
    </p>
    <p class="mt-4 text-xs text-muted-foreground">
      {table_count} tables · the grouping and the prose live in
      <a href={map_url} class="underline underline-offset-4">config/data_model.yml</a>, and a test fails when a table is
      missing from it
    </p>
  </div>
</header>

<div class="mx-auto max-w-6xl px-6 py-10 lg:px-8">
  <nav aria-label="Area" class="mb-8">
    <label class="block lg:hidden">
      <span class="mb-2 block text-xs font-semibold uppercase tracking-widest text-muted-foreground">Area</span>
      <select class="select select-bordered w-full" value={area.id} onchange={pickArea}>
        {#each areas as candidate}
          <option value={candidate.id}>{candidate.title} ({candidate.table_count})</option>
        {/each}
      </select>
    </label>
    <ul class="hidden flex-wrap gap-2 lg:flex">
      {#each areas as candidate}
        <li>
          <a
            href={`/data-model/${candidate.id}`}
            use:inertia
            aria-current={candidate.id === area.id ? 'page' : undefined}
            class="inline-flex items-center gap-2 rounded-full border px-3 py-1 text-sm transition-colors {candidate.id ===
            area.id
              ? 'border-foreground bg-foreground text-background'
              : 'border-border text-muted-foreground hover:border-foreground hover:text-foreground'}">
            {candidate.title}
            <span class="text-xs opacity-70">{candidate.table_count}</span>
          </a>
        </li>
      {/each}
    </ul>
  </nav>

  <section class="max-w-3xl">
    <h2 class="text-2xl font-semibold tracking-tight">{area.title}</h2>
    <p class="mt-3 text-muted-foreground">{area.summary}</p>
  </section>

  <section class="mt-10" aria-label="Diagram">
    <h3 class="text-xs font-semibold uppercase tracking-widest text-muted-foreground">Keys between the tables</h3>
    <p class="mt-1 text-sm text-muted-foreground">
      Each box shows a table's primary and foreign keys; the full columns are below. A box with no keys is a table from
      another area that one of these points at.
    </p>
    <div class="diagram mt-4 overflow-x-auto rounded-lg border bg-card p-4">
      {#if svg}
        {@html svg}
      {:else if rendering}
        <p class="text-sm text-muted-foreground">Drawing…</p>
      {:else}
        <p class="text-sm text-muted-foreground">
          The diagram could not be drawn ({diagramError}); the source is below.
        </p>
      {/if}
    </div>
    <details class="mt-2">
      <summary class="cursor-pointer text-sm text-muted-foreground">Mermaid source</summary>
      <pre class="mt-2 overflow-x-auto rounded-lg border bg-muted/40 p-4 text-xs"><code>{area.diagram}</code></pre>
    </details>
  </section>

  <section class="mt-12 space-y-10" aria-label="Tables">
    {#each area.tables as table (table.name)}
      <article id={table.name} class="scroll-mt-8 rounded-lg border bg-card">
        <header class="flex flex-wrap items-baseline justify-between gap-3 border-b px-5 py-4">
          <h3 class="font-mono text-lg font-semibold">{table.name}</h3>
          {#if table.areas.length > 1}
            <p class="text-xs text-muted-foreground">
              also in
              {#each table.areas.filter((id) => id !== area.id) as other, index}
                {index > 0 ? ', ' : ''}<a
                  href={`/data-model/${other}#${table.name}`}
                  use:inertia
                  class="underline underline-offset-4">{areaTitle(other)}</a>
              {/each}
            </p>
          {/if}
        </header>
        <div class="grid gap-6 px-5 py-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
          <table class="w-full text-sm">
            <thead class="text-left text-xs uppercase tracking-widest text-muted-foreground">
              <tr
                ><th class="pb-2 pr-4 font-semibold">Column</th><th class="pb-2 pr-4 font-semibold">Type</th><th
                  class="pb-2 font-semibold">Null</th
                ></tr>
            </thead>
            <tbody>
              {#each table.columns as column}
                <tr class="border-t">
                  <td class="py-1 pr-4 font-mono">{column.name}{column.primary_key ? ' 🔑' : ''}</td>
                  <td class="py-1 pr-4 text-muted-foreground">{column.type}</td>
                  <td class="py-1 text-muted-foreground">{column.null ? 'yes' : 'no'}</td>
                </tr>
              {/each}
            </tbody>
          </table>
          <div class="space-y-4 text-sm">
            <div>
              <h4 class="text-xs font-semibold uppercase tracking-widest text-muted-foreground">Points at</h4>
              {#if table.references.length === 0}
                <p class="mt-1 text-muted-foreground">nothing</p>
              {:else}
                <ul class="mt-1 space-y-1">
                  {#each table.references as reference}
                    <li>
                      <span class="font-mono">{reference.column}</span>
                      <span class="text-muted-foreground">→</span>
                      <a href={referenceHref(reference)} use:inertia class="font-mono underline underline-offset-4"
                        >{reference.table}</a>
                      {#if reference.area}
                        <span class="text-xs text-muted-foreground">({reference.area.title})</span>
                      {/if}
                    </li>
                  {/each}
                </ul>
              {/if}
            </div>
            <div>
              <h4 class="text-xs font-semibold uppercase tracking-widest text-muted-foreground">
                Pointed at by {table.referenced_by.length}
              </h4>
              {#if table.referenced_by.length === 0}
                <p class="mt-1 text-muted-foreground">nothing</p>
              {:else if table.referenced_by.length <= 6}
                <ul class="mt-1 space-y-1">
                  {#each table.referenced_by as reference}
                    <li>
                      <a href={referenceHref(reference)} use:inertia class="font-mono underline underline-offset-4"
                        >{reference.table}</a>
                      <span class="font-mono text-muted-foreground">.{reference.column}</span>
                    </li>
                  {/each}
                </ul>
              {:else}
                <details class="mt-1">
                  <summary class="cursor-pointer text-muted-foreground">show them</summary>
                  <ul class="mt-1 space-y-1">
                    {#each table.referenced_by as reference}
                      <li>
                        <a href={referenceHref(reference)} use:inertia class="font-mono underline underline-offset-4"
                          >{reference.table}</a>
                        <span class="font-mono text-muted-foreground">.{reference.column}</span>
                      </li>
                    {/each}
                  </ul>
                </details>
              {/if}
            </div>
          </div>
        </div>
      </article>
    {/each}
  </section>
</div>

<style>
  .diagram :global(svg) {
    max-width: 100%;
    height: auto;
  }
</style>
