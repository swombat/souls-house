<script>
  // One item in the Field list: what it is, who brought it, when, its tags.
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { formatWhen } from '$lib/field';
  import { formatDuration, recordingStatusLine } from '$lib/field-recordings';
  import { File, Microphone, Notepad } from 'phosphor-svelte';

  let { item, selected = false, onSelect } = $props();

  const kindLabel = { file: 'File', note: 'Note', recording: 'Recording' };
</script>

<button onclick={() => onSelect(item.key)} class="w-full text-left" data-testid="field-item">
  <Card.Root class="hover:border-primary/50 transition-colors {selected ? 'border-primary ring-1 ring-primary' : ''}">
    <Card.Content class="p-4">
      <div class="flex items-start gap-3">
        {#if item.kind === 'file'}
          <File class="size-5 text-muted-foreground shrink-0 mt-0.5" weight="duotone" />
        {:else if item.kind === 'recording'}
          <Microphone class="size-5 text-muted-foreground shrink-0 mt-0.5" weight="duotone" />
        {:else}
          <Notepad class="size-5 text-muted-foreground shrink-0 mt-0.5" weight="duotone" />
        {/if}
        <div class="flex-1 min-w-0">
          <h3 class="font-semibold truncate">{item.title}</h3>
          {#if item.kind === 'recording'}
            <p
              class="text-sm line-clamp-2 mt-1 {item.status === 'rejected' || item.status === 'failed'
                ? 'text-destructive'
                : 'text-muted-foreground'}"
              data-testid="field-recording-line">
              {recordingStatusLine(item)}
            </p>
          {:else if item.kind === 'file' && item.note}
            <p class="text-sm text-muted-foreground line-clamp-2 mt-1">{item.note}</p>
          {:else if item.kind === 'note' && item.summary}
            <p class="text-sm text-muted-foreground line-clamp-2 mt-1">{item.summary}</p>
          {/if}
          <p class="text-xs text-muted-foreground mt-2">
            {kindLabel[item.kind]}
            {#if item.kind === 'recording' && item.duration_ms}· {formatDuration(item.duration_ms)}{/if}
            {#if item.kind !== 'note' && item.uploader_name}· {item.uploader_name}{/if}
            {#if item.kind === 'note' && item.editor_name}· {item.editor_name}{/if}
            · {formatWhen(item.created_at)}
          </p>
          {#if item.tags?.length}
            <p class="text-xs text-muted-foreground mt-1" data-testid="field-item-tags">
              {item.tags.join(' · ')}
            </p>
          {/if}
        </div>
      </div>
    </Card.Content>
  </Card.Root>
</button>
