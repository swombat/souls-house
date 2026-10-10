<script>
  // One item in the compact Field list: a single line with the kind, the
  // title, a status when a recording isn't ready, and the date. Used once a
  // list holds more than a handful of items. On a phone, where there's no
  // hover, the gist and the date take a second line under the title.
  import { formatWhen } from '$lib/field';
  import { recordingStatusLine } from '$lib/field-recordings';
  import { File, Microphone, Notepad } from 'phosphor-svelte';

  let { item, selected = false, onSelect } = $props();

  const kindLabel = { file: 'File', note: 'Note', recording: 'Recording' };
  const pending = $derived(item.kind === 'recording' && item.status !== 'ready');
  const broken = $derived(item.kind === 'recording' && (item.status === 'rejected' || item.status === 'failed'));
  const hint = $derived(
    [
      item.title,
      item.summary_long || item.summary_short,
      kindLabel[item.kind],
      item.kind === 'recording' ? recordingStatusLine(item) : null,
      item.kind === 'note' ? item.editor_name : item.uploader_name,
      item.tags?.length ? item.tags.join(' · ') : null,
    ]
      .filter(Boolean)
      .join(' — ')
  );
</script>

<button
  onclick={() => onSelect(item.key)}
  title={hint}
  aria-current={selected ? 'true' : undefined}
  class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm transition-colors hover:bg-muted/60 sm:py-1.5 {selected
    ? 'bg-primary/10 font-medium'
    : ''}"
  data-testid="field-item">
  {#if item.kind === 'file'}
    <File class="size-4 text-muted-foreground shrink-0" weight="duotone" aria-label={kindLabel.file} />
  {:else if item.kind === 'recording'}
    <Microphone class="size-4 text-muted-foreground shrink-0" weight="duotone" aria-label={kindLabel.recording} />
  {:else}
    <Notepad class="size-4 text-muted-foreground shrink-0" weight="duotone" aria-label={kindLabel.note} />
  {/if}
  <span class="flex-1 min-w-0">
    <span class="block truncate">{item.title}</span>
    <span class="block truncate text-xs font-normal text-muted-foreground sm:hidden">
      {[item.summary_short, formatWhen(item.created_at)].filter(Boolean).join(' · ')}
    </span>
  </span>
  {#if pending}
    <span
      class="shrink-0 text-xs {broken ? 'text-destructive' : 'text-muted-foreground'}"
      data-testid="field-recording-line">
      {broken ? 'Failed' : recordingStatusLine(item)}
    </span>
  {/if}
  <span class="hidden shrink-0 text-xs text-muted-foreground tabular-nums sm:inline"
    >{formatWhen(item.created_at)}</span>
</button>
