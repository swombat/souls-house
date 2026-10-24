<script>
  import FieldSummary from '$lib/components/field/FieldSummary.svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DownloadSimple, LinkSimple, Trash } from 'phosphor-svelte';
  import { formatBytes, formatWhen } from '$lib/field';
  import PdfText from '$lib/components/field/PdfText.svelte';

  let { file, link, onDelete } = $props();
  let copied = $state(false);

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(link);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      copied = false;
    }
  }
</script>

<Card.Root data-testid="field-file-viewer">
  <Card.Content class="p-6 space-y-4">
    <div>
      <h2 class="text-xl font-semibold break-words">{file.title}</h2>
      <p class="text-sm text-muted-foreground mt-1">
        {#if file.uploader_name}
          Brought by {file.uploader_name}{file.uploader_kind === 'resident' ? ' (resident)' : ''} ·
        {/if}
        {#if file.dated_at}Dated {formatWhen(file.dated_at)} ·
        {/if}{formatWhen(file.created_at)}
      </p>
    </div>

    {#if file.summary_long}
      <FieldSummary
        text={file.summary_long}
        pending={file.summary_pending}
        failed={file.summary_failed}
        freshness={file.summary_freshness}
        url={file.resummarize_url}
        testid="field-file-summary">
        {#if file.summary_partial}
          <span class="text-muted-foreground" data-testid="field-file-summary-partial">
            (from the readable pages only)</span>
        {/if}
      </FieldSummary>
    {/if}

    {#if file.note}
      <div>
        <p class="text-xs uppercase tracking-wide text-muted-foreground mb-1">Why I'm bringing this</p>
        <p class="whitespace-pre-wrap">{file.note}</p>
      </div>
    {/if}

    <p class="text-sm text-muted-foreground">
      {file.filename} · {formatBytes(file.byte_size)}{file.content_type ? ` · ${file.content_type}` : ''}
    </p>

    {#if file.text_extraction}
      <PdfText extraction={file.text_extraction} pages={file.pages} />
    {/if}

    <div class="flex flex-wrap gap-2">
      {#if file.download_url}
        <Button href={file.download_url} variant="outline" size="sm">
          <DownloadSimple class="size-4" /> Download
        </Button>
      {/if}
      <Button variant="outline" size="sm" onclick={copyLink}>
        <LinkSimple class="size-4" />
        {copied ? 'Copied' : 'Copy link'}
      </Button>
      <Button variant="ghost" size="sm" onclick={onDelete}>
        <Trash class="size-4" /> Delete
      </Button>
    </div>
    <p class="text-xs text-muted-foreground break-all">{link}</p>
  </Card.Content>
</Card.Root>
