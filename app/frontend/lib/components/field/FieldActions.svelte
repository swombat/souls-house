<script>
  // The three ways into the Field. On a phone they share the width as three
  // equal tiles, icon above a short label; from sm up they sit in a row.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { FileArrowUp, Microphone, NotePencil } from 'phosphor-svelte';

  let { onFile, onNote, onRecording } = $props();

  const tile = 'h-auto flex-col gap-1 px-1 py-2 text-xs sm:h-9 sm:flex-row sm:gap-2 sm:px-4 sm:py-2 sm:text-sm';
</script>

<div class="grid w-full grid-cols-3 gap-2 sm:flex sm:w-auto" data-testid="field-actions">
  <Button class={tile} onclick={onFile} data-testid="field-add-file">
    <FileArrowUp class="size-5 sm:size-4" /> Add file
  </Button>
  <Button class={tile} variant="outline" onclick={onNote} data-testid="field-new-note">
    <NotePencil class="size-5 sm:size-4" /> New note
  </Button>
  <Button class={tile} variant="outline" onclick={onRecording} data-testid="field-add-recording">
    <Microphone class="size-5 sm:size-4" />
    <span class="sm:hidden">Recording</span><span class="hidden sm:inline">Bring in a recording</span>
  </Button>
</div>
