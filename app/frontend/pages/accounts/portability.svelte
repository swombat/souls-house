<script>
  import { onDestroy } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  // Account export and import (docs/features/account-portability.md). The
  // export is made in the background and kept privately for a week; an
  // import is checked first, previewed, and only then created.
  let {
    account,
    exports = [],
    imports = [],
    residents = [],
    destination_refusal: destinationRefusal = null,
    limits = {},
    never_travels: neverTravels = [],
    conversations_warning: conversationsWarning = '',
    export_url: exportUrl,
    import_url: importUrl,
  } = $props();

  let includeConversations = $state(false);
  let archive = $state(null);
  let confirmed = $state({});
  let busy = $state(false);

  const skipped = $derived(residents.filter((resident) => !resident.exportable));
  const working = $derived(
    exports.some((e) => ['queued', 'running'].includes(e.status)) ||
      imports.some((i) => ['uploaded', 'validating', 'importing'].includes(i.status))
  );

  let timer;
  $effect(() => {
    clearInterval(timer);
    if (working)
      timer = setInterval(() => router.reload({ only: ['exports', 'imports', 'destination_refusal'] }), 3000);
  });
  onDestroy(() => clearInterval(timer));

  function size(bytes) {
    if (bytes === null || bytes === undefined) return '';
    const units = ['bytes', 'KB', 'MB', 'GB'];
    let value = bytes;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
  }

  function gib(bytes) {
    return `${Math.round(bytes / 1024 ** 3)} GiB`;
  }

  function date(value) {
    return value
      ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
      : '';
  }

  function startExport() {
    busy = true;
    router.post(
      exportUrl,
      { include_conversations: includeConversations ? 'true' : 'false' },
      { preserveScroll: true, onFinish: () => (busy = false) }
    );
  }

  function upload() {
    if (!archive) return;
    busy = true;
    router.post(
      importUrl,
      { archive },
      { forceFormData: true, preserveScroll: true, onFinish: () => ((busy = false), (archive = null)) }
    );
  }

  function confirmImport(item) {
    busy = true;
    router.post(
      `${importUrl}/${item.id}/confirm`,
      { sha256: item.preview.sha256, confirmed: 'true' },
      { preserveScroll: true, onFinish: () => (busy = false) }
    );
  }

  const exportStatus = {
    queued: 'Waiting to start',
    running: 'Being made',
    ready: 'Ready to download',
    failed: 'Failed',
    expired: 'Expired and removed',
  };
  const importStatus = {
    uploaded: 'Uploaded',
    validating: 'Being checked',
    previewed: 'Checked; waiting for you to confirm',
    invalid: 'Refused',
    importing: 'Being imported',
    imported: 'Imported',
    failed: 'Stopped; can be retried',
  };
</script>

<svelte:head>
  <title>Export and import · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="portability"
  title="Export and import"
  description="Take this account's residents, Field and setup elsewhere as one archive, or bring an archive into an empty account.">
  <section class="space-y-4 rounded-lg border p-5" data-testid="account-export">
    <h2 class="text-xl font-semibold">Export this account</h2>
    <p class="text-sm text-muted-foreground">
      One ZIP: each stopped resident's own archive, the whole Field with its original files and audio, transcripts,
      notes and tags, rooms and their model defaults, rhythms, reflexes, the transcription glossary, and the names of
      the services to reconnect. Never included: {neverTravels.join('; ')}.
    </p>

    {#if skipped.length > 0}
      <div
        class="rounded border border-amber-500/60 bg-amber-50 p-3 text-sm text-amber-800 dark:bg-amber-950/30 dark:text-amber-300"
        data-testid="export-skipped-warning">
        <p class="font-medium">
          {skipped.length === 1 ? 'One resident' : `${skipped.length} residents`} would be skipped right now, so the archive
          would be a partial export:
        </p>
        <ul class="mt-1 list-disc pl-5">
          {#each skipped as resident (resident.name)}
            <li>{resident.name}: {resident.reason}</li>
          {/each}
        </ul>
        <p class="mt-1">
          Exporting never stops a resident. For a complete export, use "Stop for export" on each resident's Export tab
          first, then come back.
        </p>
      </div>
    {/if}

    <label class="flex items-start gap-2 text-sm">
      <input type="checkbox" bind:checked={includeConversations} data-testid="include-conversations" />
      <span>
        Include conversations.
        <span class="block text-muted-foreground">{conversationsWarning}</span>
      </span>
    </label>

    <p class="text-xs text-muted-foreground">
      Limits: {gib(limits.compressed)} archive, {gib(limits.expanded)} unpacked, {limits.entries?.toLocaleString()} items,
      {gib(limits.entry)} per file. The archive is kept privately for 7 days. It is not encrypted.
    </p>
    <Button onclick={startExport} disabled={busy || working}>Export this account</Button>

    {#if exports.length > 0}
      <ul class="space-y-2 text-sm">
        {#each exports as item (item.id)}
          <li class="rounded border p-3" data-testid="account-export-row">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <span
                >{date(item.created_at)} · {exportStatus[item.status]}{item.include_conversations
                  ? ' · with conversations'
                  : ''}</span>
              {#if item.download_url}
                <a class="font-medium underline underline-offset-4" href={item.download_url}>
                  Download ({size(item.byte_size)})
                </a>
              {/if}
            </div>
            {#if item.status === 'running' && item.progress?.step}
              <p class="text-xs text-muted-foreground">
                {item.progress.step}{item.progress.total ? ` ${item.progress.done + 1} of ${item.progress.total}` : ''}
              </p>
            {/if}
            {#if item.error}<p class="text-xs text-destructive">{item.error}</p>{/if}
            {#if item.partial}
              <p class="text-xs text-amber-700 dark:text-amber-300">
                Partial export. Not in it:
                {[
                  ...(item.residents || []).filter((r) => r.status === 'skipped').map((r) => `${r.name} (${r.reason})`),
                  ...(item.omitted || []).map((o) => `${o.kind} "${o.title}" (${o.reason})`),
                ].join('; ')}
              </p>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </section>

  <section class="mt-6 space-y-4 rounded-lg border p-5" data-testid="account-import">
    <h2 class="text-xl font-semibold">Import an account</h2>
    <p class="text-sm text-muted-foreground">
      Brings an account archive into this account as a copy. Residents arrive stopped, rhythms and reflexes arrive held,
      conversations arrive archived, and nothing runs until you start it. People never travel: names stay as text, and
      nobody gets access to this account because of an archive.
    </p>
    {#if destinationRefusal}
      <p class="rounded border bg-muted/30 p-3 text-sm" data-testid="import-refusal">{destinationRefusal}</p>
    {:else}
      <div class="flex flex-wrap items-center gap-3">
        <input
          type="file"
          accept=".zip,application/zip"
          data-testid="import-file"
          onchange={(event) => (archive = event.currentTarget.files?.[0] || null)} />
        <Button onclick={upload} disabled={busy || !archive || working}>Upload and check</Button>
      </div>
    {/if}

    {#if imports.length > 0}
      <ul class="space-y-3 text-sm">
        {#each imports as item (item.id)}
          <li class="space-y-2 rounded border p-3" data-testid="account-import-row">
            <p>{date(item.created_at)} · {importStatus[item.status]}</p>
            {#if item.error}<p class="text-xs text-destructive">{item.error}</p>{/if}
            {#if item.preview && ['previewed', 'failed'].includes(item.status)}
              {@const p = item.preview}
              <div class="space-y-1 text-xs" data-testid="import-preview">
                <p>
                  From "{p.account_name}", exported {date(p.created_at)}{p.partial ? ' (partial export)' : ''}.
                  {#if p.same_installation}
                    <strong>This archive was made on this house: importing makes a second, separate copy.</strong>
                  {/if}
                </p>
                <p>
                  Residents: {p.residents
                    .filter((r) => r.status === 'included')
                    .map((r) => r.name)
                    .join(', ') || 'none'}.
                  {#each p.residents.filter((r) => r.status === 'skipped') as r (r.key)}
                    <span class="block text-amber-700 dark:text-amber-300"
                      >{r.name} is not in the archive: {r.reason}</span>
                  {/each}
                </p>
                <p>
                  Field: {p.field.files} files, {p.field.recordings} recordings, {p.field.songs} songs, {p.field.notes} notes,
                  {p.field.tags} tags. Rooms: {p.rooms.join(', ') || 'none'}. Rhythms: {p.rhythms}. Conversations: {p.conversations}.
                </p>
                {#if p.services?.length}
                  <p>
                    Reconnect afterwards: {p.services
                      .map((s) => `${s.provider}${s.label ? ` (${s.label})` : ''}`)
                      .join(', ')}.
                  </p>
                {/if}
                {#if p.destination_refusal}<p class="text-destructive">{p.destination_refusal}</p>{/if}
                <p class="font-mono text-[11px] text-muted-foreground">SHA-256 {p.sha256}</p>
              </div>
              <label class="flex items-start gap-2 text-xs">
                <input type="checkbox" bind:checked={confirmed[item.id]} />
                <span>I understand this makes a copy, and that nothing in it runs until I start it.</span>
              </label>
              <Button size="sm" onclick={() => confirmImport(item)} disabled={busy || !confirmed[item.id]}>
                {item.status === 'failed' ? 'Retry import' : 'Import'}
              </Button>
            {/if}
            {#if item.status === 'imported' && item.result}
              <p class="text-xs" data-testid="import-result">
                Created {item.result.residents} residents, {Object.values(item.result.field || {}).reduce(
                  (a, b) => a + b,
                  0
                )}
                Field items, {item.result.rooms} rooms, {item.result.rhythms} held rhythms and {item.result
                  .conversations} archived conversations.
                {#if item.result.services_to_reconnect?.length}
                  Reconnect: {item.result.services_to_reconnect.map((s) => s.provider).join(', ')}.
                {/if}
              </p>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </section>
</AccountSettingsLayout>
