<script>
  // The top of the Field: its name, the way to its two sections (the items,
  // and the tables built from them), and the one Add button. Tables is a place
  // to go, not a thing to add, so it lives here and not under Add.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import FieldTranscriptionLinks from '$lib/components/field/FieldTranscriptionLinks.svelte';
  import FieldActions from '$lib/components/field/FieldActions.svelte';
  import { ListBullets, Table } from 'phosphor-svelte';

  let { accountId, hidden = false, onFile, onNote, onRecordNow, onRecording, onSong } = $props();
</script>

<div class="mb-6 flex-wrap items-end justify-between gap-4 {hidden ? 'hidden lg:flex' : 'flex'}">
  <div>
    <h1 class="text-3xl font-bold">Field</h1>
    <p class="text-muted-foreground mt-1">Things from your life, brought here to keep and return to together.</p>
    <FieldTranscriptionLinks {accountId} />
    <nav class="mt-3 flex gap-1" aria-label="Field sections" data-testid="field-sections">
      <Button size="sm" variant="secondary" href={`/accounts/${accountId}/field`} aria-current="page">
        <ListBullets class="size-4" /> Items
      </Button>
      <Button size="sm" variant="ghost" href={`/accounts/${accountId}/field/tables`} data-testid="field-tables-link">
        <Table class="size-4" /> Tables
      </Button>
    </nav>
  </div>
  <div class="w-full sm:w-auto">
    <FieldActions {onFile} {onNote} {onRecordNow} {onRecording} {onSong} />
  </div>
</div>
