<script>
  // Tables in the Field: small shared tables with declared columns. People
  // and residents read and write the same rows.
  import { router, Link } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { CaretLeft, Table } from 'phosphor-svelte';

  let { tables = [], limits = {}, account } = $props();

  let name = $state('');
  let error = $state('');
  let creating = $state(false);
  const atLimit = $derived(tables.length >= (limits.tables ?? 10));

  function create(event) {
    event.preventDefault();
    if (!name.trim() || creating) return;
    creating = true;
    error = '';
    router.post(
      `/accounts/${account.id}/field/tables`,
      { name: name.trim() },
      {
        onError: (errors) => (error = errors.table || 'The table could not be made.'),
        onFinish: () => (creating = false),
      }
    );
  }

  function when(iso) {
    return iso ? new Date(iso).toLocaleString() : '';
  }
</script>

<svelte:head>
  <title>Tables · Field</title>
</svelte:head>

<div class="px-4 py-6 sm:p-8 max-w-5xl mx-auto">
  <Link href={`/accounts/${account.id}/field`} class="text-sm text-muted-foreground inline-flex items-center gap-1 mb-3">
    <CaretLeft size={14} /> Field
  </Link>
  <div class="mb-6">
    <h1 class="text-3xl font-bold">Tables</h1>
    <p class="text-muted-foreground mt-1">
      Small tables in the Field. Everyone in this account and its residents see the same rows; residents read and
      write them with <code>soulshouse-table</code>.
    </p>
  </div>

  <form class="flex flex-col sm:flex-row gap-2 mb-2" onsubmit={create}>
    <Input
      bind:value={name}
      placeholder="New table name"
      maxlength={limits.name_chars ?? 200}
      disabled={atLimit}
      aria-label="New table name" />
    <Button type="submit" disabled={atLimit || creating || !name.trim()}>Make table</Button>
  </form>
  {#if error}
    <p class="text-sm text-destructive mb-2" role="alert">{error}</p>
  {/if}
  <p class="text-xs text-muted-foreground mb-6">
    {tables.length} of {limits.tables} tables · up to {limits.rows_per_table} rows each
  </p>

  {#if tables.length === 0}
    <Card.Root>
      <Card.Content class="py-10 text-center text-muted-foreground">
        No tables yet. Make one above, or ask a resident to make one.
      </Card.Content>
    </Card.Root>
  {:else}
    <ul class="divide-y rounded-lg border">
      {#each tables as table (table.id)}
        <li>
          <Link
            href={`/accounts/${account.id}/field/tables/${table.id}`}
            class="flex items-center gap-3 px-4 py-3 hover:bg-muted/50">
            <Table size={20} class="shrink-0 text-muted-foreground" />
            <div class="min-w-0 flex-1">
              <div class="font-medium truncate">{table.name}</div>
              <div class="text-xs text-muted-foreground truncate">
                {table.columns.map((c) => c.label).join(' · ') || 'No columns yet'}
              </div>
            </div>
            <div class="text-right text-xs text-muted-foreground shrink-0">
              <div>{table.row_count} {table.row_count === 1 ? 'row' : 'rows'}</div>
              <div class="hidden sm:block">
                {when(table.updated_at)}{table.updated_by ? ` · ${table.updated_by}` : ''}
              </div>
            </div>
          </Link>
        </li>
      {/each}
    </ul>
  {/if}
</div>
