<script>
  // Add a file to the Field: pick it, title it, say why, date it, upload.
  import { router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import SummariesNotice from '$lib/components/field/SummariesNotice.svelte';
  import OcrNotice from '$lib/components/field/OcrNotice.svelte';
  import { formatBytes } from '$lib/field';

  let {
    open = $bindable(false),
    accountId,
    maxBytes,
    maxLabel,
    sharedLine = '',
    summariesEnabled = false,
    ocrEnabled = false,
  } = $props();

  let uploadFile = $state(null);
  let uploadTitle = $state('');
  let uploadNote = $state('');
  let uploadDate = $state('');
  let uploadError = $state('');
  let uploadTooLarge = $state(false);
  let uploading = $state(false);

  function chooseFile(event) {
    const file = event.currentTarget.files?.[0] || null;
    uploadError = '';
    uploadTooLarge = false;
    uploadFile = file;
    if (file && file.size > maxBytes) {
      uploadTooLarge = true;
      uploadError = `${file.name} is ${formatBytes(file.size)}. The limit is ${maxLabel}.`;
    }
  }

  function submitUpload(event) {
    event.preventDefault();
    if (!uploadFile || uploadTooLarge) return;
    uploadError = '';
    const body = new FormData();
    body.append('field_file[file]', uploadFile);
    if (uploadTitle.trim()) body.append('field_file[title]', uploadTitle.trim());
    if (uploadNote.trim()) body.append('field_file[note]', uploadNote.trim());
    if (uploadDate) body.append('field_file[dated_at]', uploadDate);
    uploading = true;
    router.post(`/accounts/${accountId}/field/files`, body, {
      preserveState: true,
      onSuccess: () => {
        open = false;
        uploadFile = null;
        uploadTitle = '';
        uploadNote = '';
        uploadDate = '';
      },
      onError: (errors) => (uploadError = errors.dated_at || errors.file || 'The upload failed. Please try again.'),
      onFinish: () => (uploading = false),
    });
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title>Add a file to the Field</Dialog.Title>
      <Dialog.Description
        >{sharedLine}
        {#if summariesEnabled}<SummariesNotice kind="file" ocr={ocrEnabled} />{/if}
        {#if ocrEnabled}<OcrNotice kind="file" />{/if}</Dialog.Description>
    </Dialog.Header>
    <form onsubmit={submitUpload} class="space-y-4" data-testid="field-file-form">
      <div class="space-y-1">
        <Label for="field-file">File (up to {maxLabel})</Label>
        <Input id="field-file" type="file" onchange={chooseFile} required />
        <p class="text-xs text-muted-foreground">
          Any kind of file can be kept here. Residents may not be able to read every format.
        </p>
      </div>
      <div class="space-y-1">
        <Label for="field-title">Title</Label>
        <Input id="field-title" bind:value={uploadTitle} maxlength={200} placeholder={uploadFile?.name || ''} />
      </div>
      <div class="space-y-1">
        <Label for="field-note">Why I'm bringing this <span class="text-muted-foreground">(optional)</span></Label>
        <textarea
          id="field-note"
          bind:value={uploadNote}
          maxlength={2000}
          rows="3"
          class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          placeholder="I came away uneasy, but I don't know why."></textarea>
      </div>
      <div class="space-y-1">
        <Label for="field-dated-at">Date <span class="text-muted-foreground">(optional)</span></Label>
        <Input id="field-dated-at" type="date" class="w-44" bind:value={uploadDate} data-testid="field-file-date" />
        <p class="text-xs text-muted-foreground">
          When it's from, for older material. The Field orders it by this date.
        </p>
      </div>
      {#if uploadError}
        <p class="text-sm text-destructive" role="alert">{uploadError}</p>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
        <Button type="submit" disabled={!uploadFile || uploadTooLarge || uploading}>
          {uploading ? 'Uploading…' : 'Add to the Field'}
        </Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>
