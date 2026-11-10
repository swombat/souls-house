<script>
  // One Field table: the rows in a grid, one editor for adding or changing a
  // row, the columns, CSV in and out. Residents write the same rows through
  // the API; the page refreshes when anyone writes (FieldTable:<id>).
  import { router, Link } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { CaretLeft, Plus, Pencil, Trash, DownloadSimple, UploadSimple } from 'phosphor-svelte';

  let { table, rows = [], column_types = [], stones = [], limits = {}, account } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`FieldTable:${table.id}`]: ['table', 'rows'] });
  });

  const base = $derived(`/accounts/${account.id}/field/tables/${table.id}`);
  const columns = $derived(table.columns || []);
  const atLimit = $derived(rows.length >= (limits.rows_per_table ?? 1000));

  let error = $state('');
  const opts = (extra = {}) => ({
    preserveScroll: true,
    onError: (errors) => (error = errors.table || 'That change was refused.'),
    onSuccess: () => (error = ''),
    ...extra,
  });

  // -- Row editor: null (closed), { mode: 'new' } or { mode: 'edit', row }.
  let editing = $state(null);
  let draft = $state({});

  function openNew() {
    editing = { mode: 'new' };
    draft = Object.fromEntries(columns.map((c) => [c.key, '']));
  }

  function openEdit(row) {
    editing = { mode: 'edit', row };
    draft = Object.fromEntries(
      columns.map((c) => {
        const value = row.data[c.key];
        return [c.key, value === undefined || value === null ? '' : String(value)];
      })
    );
  }

  function closeEditor() {
    editing = null;
    draft = {};
  }

  function saveRow(event) {
    event.preventDefault();
    if (!editing) return;
    if (editing.mode === 'new') {
      const data = Object.fromEntries(
        Object.entries(draft).filter(([, v]) => v !== '' && v !== undefined && v !== null)
      );
      router.post(`${base}/rows`, { data }, opts({ onSuccess: () => ((error = ''), closeEditor()) }));
    } else {
      // Send every column: unchanged values are rewritten as they were, and
      // a cleared box clears the cell.
      router.patch(
        `${base}/rows/${editing.row.id}`,
        {
          // A cleared number box binds to undefined, which JSON would drop;
          // null is what clears the cell on the server.
          data: Object.fromEntries(Object.entries(draft).map(([k, v]) => [k, v === undefined || v === '' ? null : v])),
          lock_version: editing.row.lock_version,
        },
        opts({ onSuccess: () => ((error = ''), closeEditor()) })
      );
    }
  }

  function deleteRow(row) {
    if (!confirm('Delete this row?')) return;
    router.delete(`${base}/rows/${row.id}`, opts());
    if (editing?.row?.id === row.id) closeEditor();
  }

  function display(column, value) {
    if (value === undefined || value === null) return '';
    if (column.type === 'boolean') return value ? 'Yes' : 'No';
    return String(value);
  }

  // -- Columns
  let newColumn = $state({ key: '', label: '', type: 'text' });
  let renaming = $state(null);
  let renameDraft = $state({ key: '', label: '' });

  function keyFrom(label) {
    return label
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '_')
      .replace(/^_+|_+$/g, '')
      .replace(/^(\d)/, 'c_$1');
  }

  function addColumn(event) {
    event.preventDefault();
    const label = newColumn.label.trim();
    const key = (newColumn.key.trim() || keyFrom(label)).slice(0, 200);
    if (!key) return;
    router.post(
      `${base}/columns`,
      { key, label, type: newColumn.type },
      opts({ onSuccess: () => ((error = ''), (newColumn = { key: '', label: '', type: 'text' })) })
    );
  }

  function startRename(column) {
    renaming = column.key;
    renameDraft = { key: column.key, label: column.label };
  }

  function saveRename(column) {
    const payload = {};
    if (renameDraft.label.trim() && renameDraft.label.trim() !== column.label) payload.label = renameDraft.label.trim();
    if (renameDraft.key.trim() && renameDraft.key.trim() !== column.key) payload.new_key = renameDraft.key.trim();
    if (Object.keys(payload).length === 0) return (renaming = null);
    router.patch(
      `${base}/columns/${column.key}`,
      payload,
      opts({ onSuccess: () => ((error = ''), (renaming = null)) })
    );
  }

  function changeType(column, type) {
    if (type === column.type) return;
    router.patch(`${base}/columns/${column.key}`, { type }, opts());
  }

  function removeColumn(column) {
    if (!confirm(`Remove the column ${column.label}? Its values in every row go with it.`)) return;
    router.delete(`${base}/columns/${column.key}`, opts());
  }

  // -- Table
  let tableName = $state(null);
  function rename(event) {
    event.preventDefault();
    if (!tableName?.trim()) return;
    router.patch(base, { name: tableName.trim() }, opts({ onSuccess: () => ((error = ''), (tableName = null)) }));
  }

  function detachStone(stone) {
    if (!confirm(`Stop "${stone.title || 'this stone'}" reading ${table.name}?`)) return;
    router.delete(`${base}/stones/${stone.id}`, opts());
  }

  function deleteTable() {
    if (!confirm(`Delete ${table.name}? Residents will no longer see it.`)) return;
    router.delete(base);
  }

  let fileInput = $state(null);
  function importCsv(event) {
    const file = event.currentTarget.files?.[0];
    if (!file) return;
    router.post(`${base}/import`, { file }, opts({ forceFormData: true, onFinish: () => (fileInput.value = '') }));
  }

  function inputType(column) {
    if (column.type === 'number') return 'number';
    if (column.type === 'link') return 'url';
    return 'text';
  }
</script>

<svelte:head>
  <title>{table.name} · Tables</title>
</svelte:head>

<div class="px-4 py-6 sm:p-8 max-w-7xl mx-auto">
  <Link
    href={`/accounts/${account.id}/field/tables`}
    class="text-sm text-muted-foreground inline-flex items-center gap-1 mb-3">
    <CaretLeft size={14} /> Tables
  </Link>

  <div class="mb-4 flex flex-wrap items-end justify-between gap-3">
    <div class="min-w-0">
      {#if tableName === null}
        <h1 class="text-3xl font-bold break-words">
          {table.name}
          <button
            class="align-middle text-muted-foreground hover:text-foreground ml-1"
            title="Rename table"
            aria-label="Rename table"
            onclick={() => (tableName = table.name)}><Pencil size={18} /></button>
        </h1>
      {:else}
        <form class="flex gap-2" onsubmit={rename}>
          <Input bind:value={tableName} maxlength={limits.name_chars ?? 200} aria-label="Table name" />
          <Button type="submit" size="sm">Save</Button>
          <Button type="button" size="sm" variant="ghost" onclick={() => (tableName = null)}>Cancel</Button>
        </form>
      {/if}
      <p class="text-sm text-muted-foreground mt-1" data-testid="row-count">
        {rows.length} of {limits.rows_per_table} rows{table.updated_by ? ` · last change by ${table.updated_by}` : ''}
      </p>
    </div>
    <div class="flex flex-wrap gap-2">
      <Button size="sm" onclick={openNew} disabled={atLimit || columns.length === 0}>
        <Plus size={16} class="mr-1" /> Add row
      </Button>
      <Button size="sm" variant="outline" href={`${base}/export`} download>
        <DownloadSimple size={16} class="mr-1" /> Export CSV
      </Button>
      <Button size="sm" variant="outline" onclick={() => fileInput.click()}>
        <UploadSimple size={16} class="mr-1" /> Import CSV
      </Button>
      <input
        bind:this={fileInput}
        type="file"
        accept=".csv,text/csv"
        class="hidden"
        aria-label="CSV file to import"
        onchange={importCsv} />
    </div>
  </div>

  {#if error}
    <p class="mb-4 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm" role="alert">{error}</p>
  {/if}

  {#if editing}
    <Card.Root class="mb-4">
      <Card.Header>
        <Card.Title>{editing.mode === 'new' ? 'New row' : 'Edit row'}</Card.Title>
      </Card.Header>
      <Card.Content>
        <form class="grid gap-3 sm:grid-cols-2" onsubmit={saveRow}>
          {#each columns as column (column.key)}
            <label class="grid gap-1 text-sm">
              <span class="font-medium">{column.label} <span class="text-muted-foreground">({column.type})</span></span>
              {#if column.type === 'boolean'}
                <select class="h-9 rounded-md border bg-background px-2" bind:value={draft[column.key]}>
                  <option value="">—</option>
                  <option value="true">Yes</option>
                  <option value="false">No</option>
                </select>
              {:else}
                <Input
                  type={inputType(column)}
                  step={column.type === 'number' ? 'any' : undefined}
                  placeholder={column.type === 'date' ? 'YYYY-MM-DD' : ''}
                  bind:value={draft[column.key]}
                  name={column.key} />
              {/if}
            </label>
          {/each}
          <div class="flex gap-2 sm:col-span-2">
            <Button type="submit">{editing.mode === 'new' ? 'Add row' : 'Save row'}</Button>
            <Button type="button" variant="ghost" onclick={closeEditor}>Cancel</Button>
          </div>
        </form>
      </Card.Content>
    </Card.Root>
  {/if}

  <div class="overflow-x-auto rounded-lg border mb-8">
    <table class="w-full text-sm">
      <thead class="bg-muted/50">
        <tr>
          {#each columns as column (column.key)}
            <th class="px-3 py-2 text-left font-medium whitespace-nowrap">{column.label}</th>
          {/each}
          <th class="px-3 py-2 w-20"><span class="sr-only">Actions</span></th>
        </tr>
      </thead>
      <tbody>
        {#each rows as row (row.id)}
          <tr class="border-t align-top" data-row-id={row.id}>
            {#each columns as column (column.key)}
              <td class="px-3 py-2 max-w-xs break-words">
                {#if column.type === 'link' && row.data[column.key]}
                  <a href={row.data[column.key]} target="_blank" rel="noopener noreferrer" class="underline break-all"
                    >{row.data[column.key]}</a>
                {:else}
                  {display(column, row.data[column.key])}
                {/if}
              </td>
            {/each}
            <td class="px-2 py-1 whitespace-nowrap text-right">
              <button
                class="p-1 text-muted-foreground hover:text-foreground"
                title="Edit row"
                aria-label="Edit row"
                onclick={() => openEdit(row)}><Pencil size={16} /></button>
              <button
                class="p-1 text-muted-foreground hover:text-destructive"
                title="Delete row"
                aria-label="Delete row"
                onclick={() => deleteRow(row)}><Trash size={16} /></button>
            </td>
          </tr>
        {:else}
          <tr>
            <td class="px-3 py-8 text-center text-muted-foreground" colspan={columns.length + 1}>
              {columns.length === 0 ? 'Add a column below to start.' : 'No rows yet.'}
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>

  <h2 class="text-lg font-semibold mb-2">Columns</h2>
  <p class="text-sm text-muted-foreground mb-3">
    Residents write by key. A value has to fit its column's type; a key that isn't a column is refused.
  </p>
  <ul class="divide-y rounded-lg border mb-3">
    {#each columns as column (column.key)}
      <li class="flex flex-wrap items-center gap-2 px-3 py-2">
        {#if renaming === column.key}
          <Input class="w-40" bind:value={renameDraft.label} aria-label="Column label" />
          <Input class="w-40 font-mono" bind:value={renameDraft.key} aria-label="Column key" />
          <Button size="sm" onclick={() => saveRename(column)}>Save</Button>
          <Button size="sm" variant="ghost" onclick={() => (renaming = null)}>Cancel</Button>
        {:else}
          <span class="font-medium">{column.label}</span>
          <code class="text-xs text-muted-foreground">{column.key}</code>
          <span class="flex-1"></span>
          <select
            class="h-8 rounded-md border bg-background pl-2 pr-8 text-sm"
            aria-label={`Type of ${column.label}`}
            value={column.type}
            onchange={(e) => changeType(column, e.currentTarget.value)}>
            {#each column_types as type (type)}
              <option value={type}>{type}</option>
            {/each}
          </select>
          <button
            class="p-1 text-muted-foreground hover:text-foreground"
            title="Rename column"
            aria-label="Rename column"
            onclick={() => startRename(column)}><Pencil size={16} /></button>
          <button
            class="p-1 text-muted-foreground hover:text-destructive"
            title="Remove column"
            aria-label="Remove column"
            onclick={() => removeColumn(column)}><Trash size={16} /></button>
        {/if}
      </li>
    {/each}
  </ul>
  <form class="flex flex-wrap gap-2 mb-10" onsubmit={addColumn}>
    <Input class="w-48" bind:value={newColumn.label} placeholder="New column" aria-label="New column label" />
    <select
      class="h-9 rounded-md border bg-background pl-2 pr-8 text-sm"
      bind:value={newColumn.type}
      aria-label="New column type">
      {#each column_types as type (type)}
        <option value={type}>{type}</option>
      {/each}
    </select>
    <Button
      type="submit"
      variant="outline"
      disabled={columns.length >= (limits.columns ?? 30) || !newColumn.label.trim()}>
      Add column
    </Button>
  </form>

  {#if stones.length > 0}
    <h2 class="text-lg font-semibold mb-2">Readable through public stones</h2>
    <p class="text-sm text-muted-foreground mb-3">
      These stones read this table's rows, so anyone with their link can see them. Detach to stop that at once.
    </p>
    <ul class="divide-y rounded-lg border mb-10" data-testid="reading-stones">
      {#each stones as stone (stone.id)}
        <li class="flex flex-wrap items-center gap-2 px-3 py-2">
          <a href={stone.public_url} target="_blank" rel="noopener noreferrer" class="underline flex-1 min-w-0 truncate"
            >{stone.title || 'Stone'}</a>
          <Button size="sm" variant="outline" onclick={() => detachStone(stone)}>Detach</Button>
        </li>
      {/each}
    </ul>
  {/if}

  <div class="border-t pt-4">
    <Button variant="ghost" class="text-destructive" onclick={deleteTable}>
      <Trash size={16} class="mr-1" /> Delete table
    </Button>
  </div>
</div>
