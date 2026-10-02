<script>
  import { onDestroy } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import ResidentPortabilityWarning from '$lib/components/agents/resident-portability-warning.svelte';
  import { accountAgentsPath } from '@/routes';

  let { account, preview_url: previewUrl, import_url: importUrl } = $props();
  let archive = $state(null);
  let preview = $state(null);
  let name = $state('');
  let confirmed = $state(false);
  let busy = $state(false);
  let error = $state('');
  let controller;

  onDestroy(() => controller?.abort());

  function selectArchive(event) {
    archive = event.currentTarget.files?.[0] || null;
    preview = null;
    name = '';
    confirmed = false;
    error = '';
  }

  async function submit(confirmImport = false) {
    if (busy) return;
    error = '';
    if (!archive) {
      error = 'Choose a resident .tar.gz archive first.';
      return;
    }
    if (confirmImport && (!preview || !name.trim() || !confirmed)) {
      error = 'Enter a name and confirm the separate copy and privacy warning.';
      return;
    }

    busy = true;
    controller = new AbortController();
    const body = new FormData();
    body.append('archive', archive);
    if (confirmImport) {
      body.append('name', name.trim());
      body.append('confirmed', 'true');
    } else {
      preview = null;
      confirmed = false;
    }

    try {
      const response = await fetch(confirmImport ? importUrl : previewUrl, {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body,
        signal: controller.signal,
      });
      if (confirmImport && response.ok && response.redirected) {
        router.visit(response.url);
        return;
      }
      const data = await response.json();
      if (!response.ok) {
        const details = data.errors ? Object.values(data.errors).flat().join(' ') : null;
        throw new Error(data.error || details || 'The archive could not be processed.');
      }
      if (confirmImport) {
        if (!data.redirect_url)
          throw new Error('Import returned no destination. Check the residents list before retrying.');
        router.visit(data.redirect_url);
      } else {
        if (!data.preview || typeof data.preview.name !== 'string' || !data.preview.export_id) {
          throw new Error('The server returned an invalid preview.');
        }
        preview = data.preview;
        name = preview.name;
      }
    } catch (failure) {
      if (failure.name !== 'AbortError') {
        error =
          failure instanceof SyntaxError
            ? 'The server returned an unreadable response. Please try again.'
            : failure.message || 'Upload failed. Please try again.';
      }
    } finally {
      busy = false;
    }
  }
</script>

<svelte:head>
  <title>Import a resident</title>
</svelte:head>

<div class="p-8 max-w-3xl mx-auto space-y-6">
  <a class="text-sm text-primary underline" href={accountAgentsPath(account.id)}>Back to residents</a>
  <h1 class="text-2xl font-bold">Import a resident</h1>
  <ResidentPortabilityWarning />
  <form
    class="space-y-4"
    onsubmit={(event) => {
      event.preventDefault();
      submit();
    }}>
    <label class="block space-y-2">
      <span class="text-sm font-medium">Resident archive (.tar.gz)</span>
      <input
        class="block w-full rounded-md border border-input p-2 text-sm"
        type="file"
        accept=".tar.gz,.tgz,application/gzip"
        disabled={busy}
        onchange={selectArchive} />
    </label>
    <p class="text-sm text-muted-foreground">
      Preview validates the archive without creating a resident. Keep this page open: the selected file stays in your
      browser and is uploaded again when you confirm.
    </p>
    <Button type="submit" disabled={busy}>{busy ? 'Uploading…' : 'Preview archive'}</Button>
  </form>

  {#if error}
    <p role="alert" class="text-sm text-destructive">{error}</p>
  {/if}

  {#if preview}
    <section class="rounded-lg border border-border p-5 space-y-4">
      <h2 class="text-lg font-semibold">Archive preview</h2>
      <dl class="grid grid-cols-2 gap-2 text-sm">
        <dt>Source name</dt>
        <dd>{preview.name}</dd>
        <dt>Source resident</dt>
        <dd>{preview.source_resident_id || 'Unknown'}</dd>
        <dt>Export ID</dt>
        <dd class="break-all">{preview.export_id}</dd>
        <dt>Exported at</dt>
        <dd>{preview.created_at || 'Unknown'}</dd>
        <dt>Files</dt>
        <dd>{preview.files_count ?? 'Unknown'}</dd>
        <dt>Memory nodes</dt>
        <dd>{preview.graph_nodes ?? 'Unknown'}</dd>
        <dt>Memory edges</dt>
        <dd>{preview.graph_edges ?? 'Unknown'}</dd>
      </dl>
      {#if preview.duplicate}
        <p role="status" class="text-sm font-medium">
          This export has already been imported here. You may still create another separate copy.
        </p>
      {/if}
      {#if preview.warnings?.length}
        <ul class="list-disc pl-5 text-sm">
          {#each preview.warnings as warning}
            <li>{warning}</li>
          {/each}
        </ul>
      {/if}
      <form
        class="space-y-4"
        onsubmit={(event) => {
          event.preventDefault();
          submit(true);
        }}>
        <label class="block space-y-2">
          <span class="text-sm font-medium">Name for the new resident</span>
          <input
            class="w-full rounded-md border border-input bg-background px-3 py-2"
            bind:value={name}
            required
            disabled={busy} />
        </label>
        <label class="flex items-start gap-2 text-sm">
          <input class="mt-1" type="checkbox" bind:checked={confirmed} disabled={busy} />
          <span>
            I understand this creates a separate, stopped copy, leaves the original unchanged, and that the archive is
            confidential and unencrypted and may contain secrets.
          </span>
        </label>
        <Button type="submit" disabled={busy || !confirmed || !name.trim()}>
          {busy ? 'Importing…' : 'Import stopped copy'}
        </Button>
      </form>
    </section>
  {/if}
</div>
