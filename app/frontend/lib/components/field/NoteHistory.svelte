<script>
  // The saved past states of one Field note. Each entry is the note as it
  // stood before a change; reading one shows its text, read-only.
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Streamdown } from 'svelte-streamdown';
  import { mode } from 'mode-watcher';
  import { formatWhenWithTime } from '$lib/field';
  import { createNoteHistoryLoader } from '$lib/note-history';

  let { open = $bindable(false), accountId, note } = $props();

  let history = $state({
    versions: [],
    hasMore: false,
    loading: false,
    reading: null,
    readingLoading: false,
    error: '',
  });
  const loader = createNoteHistoryLoader({ onChange: (next) => (history = next) });

  const shikiTheme = $derived(mode.current === 'dark' ? 'catppuccin-mocha' : 'catppuccin-latte');
  const eventWords = { edited: 'Replaced', deleted: 'Deleted', restored: 'Restored' };

  // Load when the dialog opens or switches note; forget everything when it
  // closes. Keyed on the note id so a live update to the same note doesn't
  // throw away the version being read.
  let loadedKey = null;
  $effect(() => {
    const key = open && note ? `${accountId}:${note.id}` : null;
    if (key === loadedKey) return;
    loadedKey = key;
    loader.reset();
    if (key) loader.load(accountId, note.id);
  });

  function describe(version) {
    const when = formatWhenWithTime(version.replaced_at);
    const who = version.replaced_by ? ` by ${version.replaced_by}` : '';
    return `${eventWords[version.event] || 'Replaced'} ${when}${who}`;
  }

  function loadOlder() {
    const last = history.versions[history.versions.length - 1];
    if (last) loader.load(accountId, note.id, { before: last.id });
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-3xl max-h-[85vh] flex flex-col" data-testid="note-history">
    <Dialog.Header>
      <Dialog.Title>History of "{note?.title}"</Dialog.Title>
      <Dialog.Description>
        Earlier states of this note, newest first. Each one is how the note read before the change named under it.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex-1 overflow-y-auto">
      {#if history.error}
        <p class="text-sm text-destructive" role="alert">{history.error}</p>
      {/if}

      {#if history.reading}
        <div class="mb-3 flex items-center justify-between gap-2">
          <div>
            <p class="font-medium">{history.reading.name}</p>
            <p class="text-xs text-muted-foreground">
              Revision {history.reading.revision}
              {#if history.reading.edited_at}· written {formatWhenWithTime(history.reading.edited_at)}{/if}
              {#if history.reading.edited_by}by {history.reading.edited_by}{/if}
            </p>
          </div>
          <Button size="sm" variant="outline" onclick={() => loader.back()}>Back to the list</Button>
        </div>
        {#if history.reading.content?.trim()}
          <div
            class="prose dark:prose-invert max-w-none border border-border rounded-md p-4"
            data-testid="note-version-content">
            <Streamdown
              content={history.reading.content}
              parseIncompleteMarkdown={false}
              baseTheme="shadcn"
              {shikiTheme}
              shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']} />
          </div>
        {:else}
          <p class="text-muted-foreground text-center py-8">This version was empty.</p>
        {/if}
      {:else if history.loading && history.versions.length === 0}
        <p class="text-muted-foreground text-center py-8">Loading…</p>
      {:else if history.versions.length === 0}
        <p class="text-muted-foreground text-center py-8">
          No earlier versions yet. History starts with the first change after versioning was switched on.
        </p>
      {:else}
        <ul class="divide-y divide-border">
          {#each history.versions as version (version.id)}
            <li>
              <button
                type="button"
                class="w-full text-left px-2 py-3 hover:bg-muted/50 rounded-md disabled:opacity-50"
                disabled={history.readingLoading}
                onclick={() => loader.read(accountId, note.id, version.id)}
                data-testid="note-version">
                <p class="text-sm font-medium">
                  Revision {version.revision}
                  <span class="text-muted-foreground font-normal">· {version.content_length} characters</span>
                </p>
                <p class="text-xs text-muted-foreground">{describe(version)}</p>
              </button>
            </li>
          {/each}
        </ul>
        {#if history.hasMore}
          <div class="pt-3 text-center">
            <Button size="sm" variant="outline" disabled={history.loading} onclick={loadOlder}>Older versions</Button>
          </div>
        {/if}
      {/if}
    </div>
  </Dialog.Content>
</Dialog.Root>
