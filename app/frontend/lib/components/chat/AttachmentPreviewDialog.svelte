<script>
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DownloadSimple } from 'phosphor-svelte';
  import { Streamdown } from 'svelte-streamdown';
  import { readTextPreview } from '$lib/attachment-preview.js';

  let { file, kind, open = $bindable(false) } = $props();

  let text = $state(null);
  let truncated = $state(false);
  let error = $state(null);
  let loading = $state(false);
  let loadedUrl = null;

  $effect(() => {
    if (!open || (kind !== 'markdown' && kind !== 'text')) return;
    if (loadedUrl === file.inline_url) return;
    loadedUrl = file.inline_url;
    loading = true;
    error = null;
    readTextPreview(file.inline_url)
      .then((result) => {
        text = result.text;
        truncated = result.truncated;
      })
      .catch((e) => {
        error = e.message;
        loadedUrl = null;
      })
      .finally(() => (loading = false));
  });
</script>

<Dialog.Root bind:open>
  <Dialog.Content
    class="sm:max-w-3xl max-h-[90vh] flex flex-col overflow-hidden"
    data-testid="attachment-preview"
    data-preview-kind={kind}>
    <Dialog.Header class="pr-8">
      <Dialog.Title class="truncate">{file.filename}</Dialog.Title>
    </Dialog.Header>

    <div class="min-h-0 overflow-auto -mx-6 px-6">
      {#if kind === 'markdown' || kind === 'text'}
        {#if loading}
          <p class="text-sm text-muted-foreground py-8 text-center">Loading…</p>
        {:else if error}
          <p class="text-sm text-destructive py-8 text-center">{error}</p>
        {:else if text !== null}
          {#if kind === 'markdown'}
            <div data-testid="attachment-preview-markdown">
              <Streamdown
                content={text}
                parseIncompleteMarkdown={false}
                baseTheme="shadcn"
                shikiPreloadThemes={['catppuccin-latte', 'catppuccin-mocha']}
                class="prose max-w-none [overflow-wrap:anywhere]" />
            </div>
          {:else}
            <pre
              class="text-xs whitespace-pre-wrap [overflow-wrap:anywhere] font-mono bg-muted/50 rounded-md p-3"
              data-testid="attachment-preview-text">{text}</pre>
          {/if}
          {#if truncated}
            <p class="text-xs text-muted-foreground mt-2">Showing the first megabyte. Download for the whole file.</p>
          {/if}
        {/if}
      {:else if kind === 'image'}
        <img src={file.inline_url} alt={file.filename} class="max-w-full max-h-[70vh] mx-auto object-contain" />
      {:else if kind === 'audio'}
        <audio controls preload="metadata" src={file.inline_url} class="w-full" data-testid="attachment-preview-audio">
        </audio>
      {:else if kind === 'video'}
        <!-- svelte-ignore a11y_media_has_caption -->
        <video controls preload="metadata" src={file.inline_url} class="w-full max-h-[70vh]"></video>
      {/if}
    </div>

    <div class="flex flex-wrap gap-2 justify-end">
      <Button href={file.url} download={file.filename} variant="outline" size="sm">
        <DownloadSimple class="size-4" /> Download
      </Button>
    </div>
  </Dialog.Content>
</Dialog.Root>
