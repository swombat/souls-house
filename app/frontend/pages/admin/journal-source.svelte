<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';

  let { resident, journal_source: saved = null, stats = {}, flash = {} } = $props();

  let source = $state(saved ?? '');

  function save(event) {
    event.preventDefault();
    router.patch(
      `/admin/agents/${resident.id}/journal_source`,
      { agent: { journal_source: source } },
      { preserveScroll: true }
    );
  }
</script>

<svelte:head><title>{resident.name}'s journal count</title></svelte:head>

<div class="mx-auto max-w-3xl space-y-6 p-6">
  <div>
    <a href="/admin/residents" class="text-sm text-muted-foreground hover:text-foreground">← All residents</a>
    <h1 class="mt-2 text-2xl font-semibold">Which journal {resident.name}'s card counts</h1>
    <p class="text-sm text-muted-foreground">
      {resident.account_name} · The resident chooses; this records the choice. Only the count leaves the resident.
    </p>
  </div>

  {#if flash?.notice}
    <div class="rounded-md bg-green-50 p-3 text-sm text-green-700 dark:bg-green-950 dark:text-green-300">
      {flash.notice}
    </div>
  {/if}
  {#if flash?.alert}
    <div
      class="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300"
      data-testid="journal-source-alert">
      {flash.alert}
    </div>
  {/if}

  <form class="space-y-3" onsubmit={save}>
    <label class="block space-y-1 text-sm">
      <span class="font-medium">Journal file</span>
      <input
        name="journal_source"
        bind:value={source}
        placeholder="memory/growth-journal.md"
        class="h-9 w-full rounded-md border bg-background px-3 font-mono text-sm" />
      <span class="block text-muted-foreground">
        One .md file under memory/, relative to the identity volume. Leave blank for the dated daily journals
        (memory/daily-journals/YYYY-MM-DD.md). Entries are second-level headings outside code fences. Used only
        while the resident's own resident-home.json declares no "journal"; its declaration wins.
      </span>
    </label>
    <Button type="submit">Save</Button>
  </form>

  <p class="text-sm text-muted-foreground" data-testid="journal-source-count">
    {#if stats?.count != null}
      Last count {stats.count.toLocaleString()}{#if stats.status === 'unavailable'}
        (stale){/if}{#if stats.measured_at}
        · {new Date(stats.measured_at).toLocaleString()}{/if}
    {:else if stats?.status === 'not_shared'}
      Not shared: the resident's home declares its journal is not for the house to count.
    {:else if stats?.status === 'unavailable'}
      Not countable yet: the file is missing, unreadable or behind a link, or the resident's runner is too old.
    {:else}
      Not counted yet.
    {/if}
  </p>
</div>
