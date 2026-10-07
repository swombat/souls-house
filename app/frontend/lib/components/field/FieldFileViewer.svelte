<script>
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DownloadSimple, LinkSimple, Trash } from 'phosphor-svelte';
  import { formatBytes, formatWhen } from '$lib/field';

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
        {formatWhen(file.created_at)}
      </p>
    </div>

    {#if file.note}
      <div>
        <p class="text-xs uppercase tracking-wide text-muted-foreground mb-1">Why I'm bringing this</p>
        <p class="whitespace-pre-wrap">{file.note}</p>
      </div>
    {/if}

    <p class="text-sm text-muted-foreground">
      {file.filename} · {formatBytes(file.byte_size)}{file.content_type ? ` · ${file.content_type}` : ''}
    </p>

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
