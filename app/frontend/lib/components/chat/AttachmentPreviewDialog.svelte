<script>
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DownloadSimple } from 'phosphor-svelte';
  import { Streamdown } from 'svelte-streamdown';
  import { LINK_PREFIXES } from '$lib/markdown-links.js';
  import { readTextPreview } from '$lib/attachment-preview.js';

  let { file, kind, open = $bindable(false) } = $props();

  let text = $state(null);
  let truncated = $state(false);
  let error = $state(null);
  let loading = $state(false);
  let loaded = false;
  let htmlMode = $state('rendered');

  $effect(() => {
    if (!open) htmlMode = 'rendered';
  });

  // Read text when the dialog opens (or when switching an HTML preview to source);
  // closing it stops an unfinished read.
  $effect(() => {
    const wantsText =
      kind === 'markdown' || kind === 'text' || (kind === 'html' && htmlMode === 'source' && !!file.text_preview_url);
    if (!open || loaded || !wantsText) return;
    const controller = new AbortController();
    loading = true;
    error = null;
    readTextPreview(file.text_preview_url, fetch, controller.signal)
      .then((result) => {
        text = result.text;
        truncated = result.truncated;
        loaded = true;
      })
      .catch((e) => {
        if (e.name !== 'AbortError') error = e.message;
      })
      .finally(() => (loading = false));
    return () => controller.abort();
  });
</script>

<Dialog.Root bind:open>
  <Dialog.Content
    class="sm:max-w-3xl max-h-[90vh] flex flex-col overflow-hidden"
    data-testid="attachment-preview"
    data-preview-kind={kind}>
    <Dialog.Header class="pr-8">
      <div class="flex items-center justify-between gap-3">
        <Dialog.Title class="truncate">{file.filename}</Dialog.Title>
        {#if kind === 'html' && file.text_preview_url}
          <div
            class="inline-flex rounded-md border border-border bg-muted/50 p-0.5 shrink-0"
            role="group"
            aria-label="HTML preview mode">
            <button
              type="button"
              onclick={() => (htmlMode = 'rendered')}
              class="px-2.5 py-1 text-xs rounded-sm transition-colors {htmlMode === 'rendered'
                ? 'bg-background text-foreground shadow-xs font-medium'
                : 'text-muted-foreground hover:text-foreground'}"
              aria-pressed={htmlMode === 'rendered'}
              data-testid="attachment-preview-html-rendered">
              Rendered
            </button>
            <button
              type="button"
              onclick={() => (htmlMode = 'source')}
              class="px-2.5 py-1 text-xs rounded-sm transition-colors {htmlMode === 'source'
                ? 'bg-background text-foreground shadow-xs font-medium'
                : 'text-muted-foreground hover:text-foreground'}"
              aria-pressed={htmlMode === 'source'}
              data-testid="attachment-preview-html-source">
              Source
            </button>
          </div>
        {/if}
      </div>
    </Dialog.Header>

    <div class="min-h-0 overflow-auto -mx-6 px-6">
      {#if kind === 'html' && htmlMode === 'rendered'}
        <iframe
          src={file.html_preview_url}
          title={file.filename}
          sandbox=""
          referrerpolicy="no-referrer"
          class="w-full h-[70vh] rounded-md border border-border bg-white"
          data-testid="attachment-preview-html"></iframe>
      {:else if kind === 'markdown' || kind === 'text' || (kind === 'html' && htmlMode === 'source')}
        {#if loading}
          <p class="text-sm text-muted-foreground py-8 text-center">Loading…</p>
        {:else if error}
          <p class="text-sm text-destructive py-8 text-center">{error}</p>
        {:else if text !== null}
          {#if kind === 'markdown'}
            <div data-testid="attachment-preview-markdown">
              <Streamdown
                allowedLinkPrefixes={LINK_PREFIXES}
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
