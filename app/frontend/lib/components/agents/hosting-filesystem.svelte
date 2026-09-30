<script>
  let { section, hostingDiagnosticsUrl, diagnosticsLoading, diagnosticsLoaded } = $props();
  let expandedFilesystemDirs = $state({});
  let filePreviews = $state({});
  function directoryKey(section, entryOrPath) {
    const path = typeof entryOrPath === 'string' ? entryOrPath : entryOrPath.path;
    return `${section.target}:${path}`;
  }

  function directoryExpanded(section, entry) {
    return expandedFilesystemDirs[directoryKey(section, entry)] === true;
  }

  function toggleDirectory(section, entry) {
    const key = directoryKey(section, entry);
    expandedFilesystemDirs = { ...expandedFilesystemDirs, [key]: !expandedFilesystemDirs[key] };
  }

  function entryVisible(section, entry) {
    if (entry.depth === 0) return true;

    const parts = entry.path.split('/');
    let ancestor = '';
    for (let index = 0; index < parts.length - 1; index += 1) {
      ancestor = ancestor ? `${ancestor}/${parts[index]}` : parts[index];
      if (!expandedFilesystemDirs[directoryKey(section, ancestor)]) return false;
    }

    return true;
  }

  function filePreviewKey(section, entry) {
    return `${section.target}:${entry.path}`;
  }

  function filePreviewUrl(section, entry) {
    const url = new URL(`${hostingDiagnosticsUrl}/file_preview`, window.location.origin);
    url.searchParams.set('target', section.target);
    url.searchParams.set('path', entry.path);
    return url.toString();
  }

  function loadFilePreview(section, entry, event) {
    if (!event.currentTarget.open || !entry.previewable || !hostingDiagnosticsUrl) return;

    const key = filePreviewKey(section, entry);
    if (filePreviews[key]?.loading || filePreviews[key]?.loaded) return;

    filePreviews = { ...filePreviews, [key]: { loading: true } };

    fetch(filePreviewUrl(section, entry), { headers: { Accept: 'application/json' } })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body })))
      .then(({ ok, body }) => {
        filePreviews = {
          ...filePreviews,
          [key]: ok ? { ...body, loaded: true } : { error: body.error || 'Could not load preview', loaded: true },
        };
      })
      .catch((error) => {
        filePreviews = { ...filePreviews, [key]: { error: error.message, loaded: true } };
      });
  }
</script>

<div class="border rounded-lg p-6 space-y-3">
  <div>
    <h2 class="text-xl font-semibold">{section.title}</h2>
    <p class="text-sm text-muted-foreground">
      {section.description}
      <span class="font-mono">({section.dump.root || section.fallbackRoot})</span>
    </p>
  </div>
  {#if section.dump.error}
    <div class="rounded border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      {section.dump.error}
    </div>
  {:else if diagnosticsLoading && !diagnosticsLoaded}
    <p class="text-sm text-muted-foreground">Loading filesystem dump…</p>
  {:else if !section.dump.entries || section.dump.entries.length === 0}
    <p class="text-sm text-muted-foreground">No files found.</p>
  {:else}
    <div class="space-y-2">
      {#each section.dump.entries as entry}
        {#if entryVisible(section, entry)}
          {#if entry.type === 'directory'}
            <button
              type="button"
              class="block w-full rounded px-2 py-1 text-left font-mono text-xs text-muted-foreground hover:bg-muted"
              style={`padding-left: ${entry.depth * 1.25 + 0.5}rem`}
              onclick={() => toggleDirectory(section, entry)}
              aria-expanded={directoryExpanded(section, entry)}>
              {directoryExpanded(section, entry) ? '▾' : '▸'} 📁 {entry.name}/
            </button>
          {:else}
            <details
              class="rounded border bg-muted/40 p-2 text-sm"
              style={`margin-left: ${entry.depth * 1.25}rem`}
              ontoggle={(event) => loadFilePreview(section, entry, event)}>
              <summary class="cursor-pointer font-mono text-xs">
                📄 {entry.name}
                {#if entry.size_bytes !== null && entry.size_bytes !== undefined}
                  <span class="text-muted-foreground">({entry.size_bytes} bytes)</span>
                {/if}
              </summary>
              {#if !entry.previewable}
                <p class="mt-2 text-xs text-muted-foreground">Preview unavailable for this file type.</p>
              {:else if filePreviews[filePreviewKey(section, entry)]?.loading}
                <p class="mt-2 text-xs text-muted-foreground">Loading preview…</p>
              {:else if filePreviews[filePreviewKey(section, entry)]?.error}
                <p class="mt-2 text-xs text-destructive">
                  {filePreviews[filePreviewKey(section, entry)].error}
                </p>
              {:else if filePreviews[filePreviewKey(section, entry)]?.loaded}
                <pre
                  class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap rounded bg-background p-3 text-xs">{filePreviews[
                    filePreviewKey(section, entry)
                  ].content}</pre>
                {#if filePreviews[filePreviewKey(section, entry)].truncated}
                  <p class="mt-1 text-xs text-muted-foreground">Preview truncated.</p>
                {/if}
              {:else}
                <p class="mt-2 text-xs text-muted-foreground">Open to load preview.</p>
              {/if}
            </details>
          {/if}
        {/if}
      {/each}
      {#if section.dump.truncated}
        <p class="text-xs text-muted-foreground">File listing truncated.</p>
      {/if}
    </div>
  {/if}
</div>
