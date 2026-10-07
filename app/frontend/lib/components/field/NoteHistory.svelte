<script>
  // The saved past states of one Field note. Each entry is the note as it
  // stood before a change; reading one shows its text, read-only.
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Streamdown } from 'svelte-streamdown';
  import { mode } from 'mode-watcher';
  import { formatWhenWithTime, noteVersionsPath } from '$lib/field';

  let { open = $bindable(false), accountId, note } = $props();

  let versions = $state([]);
  let loading = $state(false);
  let error = $state('');
  let reading = $state(null);
  let readingLoading = $state(false);

  const shikiTheme = $derived(mode.current === 'dark' ? 'catppuccin-mocha' : 'catppuccin-latte');

  const eventWords = { edited: 'Replaced', deleted: 'Deleted', restored: 'Restored' };

  $effect(() => {
    if (open && note) load(note.id);
    if (!open) {
      reading = null;
      error = '';
    }
  });

  async function load(noteId) {
    loading = true;
    error = '';
    try {
      const response = await fetch(noteVersionsPath(accountId, noteId), { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(String(response.status));
      versions = (await response.json()).versions;
    } catch {
      error = 'The history could not be loaded.';
      versions = [];
    } finally {
      loading = false;
    }
  }

  async function read(version) {
    readingLoading = true;
    error = '';
    try {
      const response = await fetch(noteVersionsPath(accountId, note.id, version.id), {
        headers: { Accept: 'application/json' },
      });
      if (!response.ok) throw new Error(String(response.status));
      reading = (await response.json()).version;
    } catch {
      error = 'That version could not be loaded.';
    } finally {
      readingLoading = false;
    }
  }

  function describe(version) {
    const when = formatWhenWithTime(version.replaced_at);
    const who = version.replaced_by ? ` by ${version.replaced_by}` : '';
    return `${eventWords[version.event] || 'Replaced'} ${when}${who}`;
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
      {#if error}
        <p class="text-sm text-destructive" role="alert">{error}</p>
      {/if}

      {#if reading}
        <div class="mb-3 flex items-center justify-between gap-2">
          <div>
            <p class="font-medium">{reading.name}</p>
            <p class="text-xs text-muted-foreground">
              Revision {reading.revision}
              {#if reading.edited_at}· written {formatWhenWithTime(reading.edited_at)}{/if}
              {#if reading.edited_by}by {reading.edited_by}{/if}
            </p>
          </div>
          <Button size="sm" variant="outline" onclick={() => (reading = null)}>Back to the list</Button>
        </div>
        {#if reading.content?.trim()}
          <div
            class="prose dark:prose-invert max-w-none border border-border rounded-md p-4"
            data-testid="note-version-content">
            <Streamdown
              content={reading.content}
              parseIncompleteMarkdown={false}
              baseTheme="shadcn"
              {shikiTheme}
              shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']} />
          </div>
        {:else}
          <p class="text-muted-foreground text-center py-8">This version was empty.</p>
        {/if}
      {:else if loading}
        <p class="text-muted-foreground text-center py-8">Loading…</p>
      {:else if versions.length === 0}
        <p class="text-muted-foreground text-center py-8">
          No earlier versions yet. History starts with the first change after versioning was switched on.
        </p>
      {:else}
        <ul class="divide-y divide-border">
          {#each versions as version (version.id)}
            <li>
              <button
                type="button"
                class="w-full text-left px-2 py-3 hover:bg-muted/50 rounded-md disabled:opacity-50"
                disabled={readingLoading}
                onclick={() => read(version)}
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
      {/if}
    </div>
  </Dialog.Content>
</Dialog.Root>
