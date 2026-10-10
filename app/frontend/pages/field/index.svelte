<script>
  import { router } from '@inertiajs/svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import WhiteboardViewer from '$lib/components/whiteboards/WhiteboardViewer.svelte';
  import FieldFileViewer from '$lib/components/field/FieldFileViewer.svelte';
  import NoteHistory from '$lib/components/field/NoteHistory.svelte';
  import RecordingUploadDialog from '$lib/components/field/RecordingUploadDialog.svelte';
  import RecordingAllowance from '$lib/components/field/RecordingAllowance.svelte';
  import RecordingViewer from '$lib/components/field/RecordingViewer.svelte';
  import FieldTagEditor from '$lib/components/field/FieldTagEditor.svelte';
  import FieldTagManager from '$lib/components/field/FieldTagManager.svelte';
  import FieldItemCard from '$lib/components/field/FieldItemCard.svelte';
  import FieldSearchBar from '$lib/components/field/FieldSearchBar.svelte';
  import FieldSearchResults from '$lib/components/field/FieldSearchResults.svelte';
  import SummariesNotice from '$lib/components/field/SummariesNotice.svelte';
  import { fieldItemLink, formatBytes } from '$lib/field';
  import { FileArrowUp, Microphone, NotePencil, Plant } from 'phosphor-svelte';

  let {
    files = [],
    notes = [],
    recordings = [],
    recording_allowance = null,
    max_recording_bytes = 2 * 1024 * 1024 * 1024,
    max_recording_label = '2 GB',
    suggestions_enabled = false,
    summaries_enabled = false,
    tab = 'all',
    selected = null,
    max_file_bytes = 100 * 1024 * 1024,
    max_file_label = '100 MB',
    account_name = '',
    account,
    tags = [],
    filter_tags = [],
    query = '',
    search = null,
  } = $props();

  const tabs = [
    { key: 'all', label: 'All' },
    { key: 'files', label: 'Files' },
    { key: 'notes', label: 'Notes' },
    { key: 'recordings', label: 'Recordings' },
  ];

  // Tag filter: an item shows when it carries every chosen tag.
  const tagged = (item) => filter_tags.every((name) => (item.tags || []).includes(name));
  const everything = $derived([...files, ...notes, ...recordings]);
  const shown = $derived(everything.filter(tagged));
  const byTab = $derived({
    all: shown,
    files: files.filter(tagged),
    notes: notes.filter(tagged),
    recordings: recordings.filter(tagged),
  });
  const items = $derived([...(byTab[tab] || shown)].sort((a, b) => (a.created_at < b.created_at ? 1 : -1)));
  const fieldEmpty = $derived(everything.length === 0);
  const current = $derived(everything.find((item) => item.key === selected) || null);
  const accountLabel = $derived(account_name || 'this account');
  const sharedLine = $derived(
    `Shared with every human member and resident in ${accountLabel}, including anyone who joins later.`
  );

  const updateSync = createDynamicSync();
  $effect(() => {
    const subs = {
      // An open search refreshes too: a transcript becoming ready, or a note
      // being edited, can change what matches.
      [`Account:${account.id}:field_files`]: ['files', 'search'],
      [`Account:${account.id}:whiteboards`]: ['notes', 'search'],
      [`Account:${account.id}:field_recordings`]: ['recordings', 'recording_allowance', 'search'],
    };
    if (current?.kind === 'note') subs[`Whiteboard:${current.id}`] = ['notes', 'search'];
    updateSync(subs);
  });

  // Search, tag filter and results page ride along in the URL so a link
  // reopens them. A new query or filter starts again from the first page.
  function visit(params, { q = query, tag = filter_tags, page = search?.page || 0 } = {}) {
    const extra = {};
    if (q) extra.q = q;
    if (tag.length) extra.tag = tag;
    if (q && page > 0) extra.page = page;
    router.get(`/accounts/${account.id}/field`, { ...params, ...extra }, { preserveState: true, preserveScroll: true });
  }

  let tagsOpen = $state(false);

  function toggleTag(name) {
    const next = filter_tags.includes(name) ? filter_tags.filter((t) => t !== name) : [...filter_tags, name];
    visit(selected ? { tab, item: selected } : { tab }, { tag: next, page: 0 });
  }

  // After a tag is renamed, merged or deleted, an active filter on its old
  // name would match nothing and have no chip to clear it: follow the change.
  function tagChanged(oldName, newName) {
    if (!filter_tags.includes(oldName)) return false;
    const next = [...new Set(filter_tags.map((name) => (name === oldName ? newName : name)).filter(Boolean))];
    visit(selected ? { tab, item: selected } : { tab }, { tag: next, page: 0 });
    return true;
  }

  function nextResults() {
    visit(selected ? { tab, item: selected } : { tab }, { page: search.next_page });
  }

  function selectTab(key) {
    visit(selected ? { tab: key, item: selected } : { tab: key });
  }

  function selectItem(key) {
    editing = false;
    conflict = null;
    visit({ tab, item: key });
  }

  let recordingOpen = $state(false);

  // Add file
  let uploadOpen = $state(false);
  let uploadFile = $state(null);
  let uploadTitle = $state('');
  let uploadNote = $state('');
  let uploadError = $state('');
  let uploadTooLarge = $state(false);
  let uploading = $state(false);

  function chooseFile(event) {
    const file = event.currentTarget.files?.[0] || null;
    uploadError = '';
    uploadTooLarge = false;
    uploadFile = file;
    if (file && file.size > max_file_bytes) {
      uploadTooLarge = true;
      uploadError = `${file.name} is ${formatBytes(file.size)}. The limit is ${max_file_label}.`;
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
    uploading = true;
    router.post(`/accounts/${account.id}/field/files`, body, {
      preserveState: true,
      onSuccess: () => {
        uploadOpen = false;
        uploadFile = null;
        uploadTitle = '';
        uploadNote = '';
      },
      onError: (errors) => (uploadError = errors.file || 'The upload failed. Please try again.'),
      onFinish: () => (uploading = false),
    });
  }

  // New note
  let noteOpen = $state(false);
  let noteName = $state('');
  let noteContent = $state('');
  let creatingNote = $state(false);
  let noteError = $state('');

  function submitNote(event) {
    event.preventDefault();
    if (!noteName.trim()) return;
    creatingNote = true;
    noteError = '';
    router.post(
      `/accounts/${account.id}/whiteboards`,
      { whiteboard: { name: noteName.trim(), content: noteContent } },
      {
        preserveState: true,
        onSuccess: () => {
          noteOpen = false;
          noteName = '';
          noteContent = '';
        },
        onError: (errors) => (noteError = errors.name || 'The note could not be saved. Please try again.'),
        onFinish: () => (creatingNote = false),
      }
    );
  }

  // Note editing, unchanged from the whiteboards page
  let editing = $state(false);
  let editContent = $state('');
  let conflict = $state(null);
  let saving = $state(false);

  function startEditing() {
    editContent = current?.content || '';
    editing = true;
  }

  function cancelEditing() {
    editing = false;
    editContent = '';
    conflict = null;
  }

  async function saveNote() {
    saving = true;
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
    try {
      const response = await fetch(`/accounts/${account.id}/whiteboards/${current.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken || '' },
        body: JSON.stringify({ whiteboard: { content: editContent }, expected_revision: current.revision }),
      });
      saving = false;
      if (response.ok) {
        editing = false;
        conflict = null;
        router.reload({ only: ['notes', 'search'], preserveScroll: true });
      } else {
        const data = await response.json();
        if (data.error === 'conflict') {
          conflict = {
            serverContent: data.current_content,
            serverRevision: data.current_revision,
            myContent: editContent,
          };
        } else {
          alert('Failed to save. Please try again.');
        }
      }
    } catch {
      saving = false;
      alert('Failed to save. Please try again.');
    }
  }

  function useServerVersion() {
    if (!conflict) return;
    editContent = conflict.serverContent;
    conflict = null;
  }

  function keepMyVersion() {
    conflict = null;
    saveNote();
  }

  let historyOpen = $state(false);

  function copyNoteLink() {
    navigator.clipboard?.writeText(fieldItemLink(account.id, current.key));
  }

  function deleteNote() {
    const message = `Delete the note "${current.title}"? Residents who already read it may have quoted it elsewhere.`;
    if (!confirm(message)) return;
    router.delete(`/accounts/${account.id}/whiteboards/${current.id}`);
  }

  function deleteFile() {
    const message =
      `Delete "${current.title}" from the Field? It disappears for everyone, people and residents. Like ` +
      'everything deleted in the house, the file itself stays stored. Deleting does not reach anything a ' +
      'resident has already read: quotes in chats and things kept in memory stay where they are.';
    if (!confirm(message)) return;
    router.delete(`/accounts/${account.id}/field/files/${current.id}`);
  }
</script>

<svelte:head>
  <title>Field</title>
</svelte:head>

<div class="p-8 max-w-7xl mx-auto">
  <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
    <div>
      <h1 class="text-3xl font-bold">Field</h1>
      <p class="text-muted-foreground mt-1">Things from your life, brought here to keep and return to together.</p>
    </div>
    <div class="flex gap-2">
      <Button onclick={() => (uploadOpen = true)} data-testid="field-add-file">
        <FileArrowUp class="size-4" /> Add file
      </Button>
      <Button variant="outline" onclick={() => (noteOpen = true)} data-testid="field-new-note">
        <NotePencil class="size-4" /> New note
      </Button>
      <Button variant="outline" onclick={() => (recordingOpen = true)} data-testid="field-add-recording">
        <Microphone class="size-4" /> Bring in a recording
      </Button>
    </div>
  </div>

  {#if fieldEmpty}
    <Card.Root>
      <Card.Content class="py-16 text-center max-w-xl mx-auto">
        <Plant class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
        <h2 class="text-xl font-semibold mb-2">Bring something into the Field.</h2>
        <p class="text-muted-foreground mb-3">
          Add files, write notes or bring in recordings to keep and return to together.
        </p>
        <p class="text-muted-foreground mb-3" data-testid="field-sharing">
          Everything here is shared with every human member and resident in {accountLabel}. Adding something doesn't
          notify or wake residents. To explore it together, share its link in a chat.
        </p>
        <p class="text-muted-foreground text-sm">Recordings are transcribed, so everyone can read them.</p>
      </Card.Content>
    </Card.Root>
  {:else}
    <FieldSearchBar
      {query}
      filterTags={filter_tags}
      {tags}
      onSearch={(q) => visit(selected ? { tab, item: selected } : { tab }, { q, page: 0 })}
      onToggleTag={toggleTag}
      onManage={() => (tagsOpen = true)} />

    <p class="text-sm text-muted-foreground mb-4" data-testid="field-sharing">
      {sharedLine} Adding something doesn't notify or wake residents; share its link in a chat to explore it together.
      {#if summaries_enabled}<SummariesNotice />{/if}
    </p>

    <!-- The tabs sort the list; a search has its own results. -->
    {#if !search}
      <div class="flex gap-1 mb-4" role="tablist">
        {#each tabs as t (t.key)}
          <Button
            variant={tab === t.key ? 'secondary' : 'ghost'}
            size="sm"
            role="tab"
            aria-selected={tab === t.key}
            onclick={() => selectTab(t.key)}>
            {t.label}
            <span class="text-muted-foreground ml-1">
              {byTab[t.key].length}
            </span>
          </Button>
        {/each}
      </div>
    {/if}

    {#if tab === 'recordings' && recording_allowance}
      <RecordingAllowance allowance={recording_allowance} />
    {/if}

    <div class="grid gap-6 lg:grid-cols-3">
      <div class="space-y-3">
        {#if search}
          <FieldSearchResults
            {search}
            {query}
            filterTags={filter_tags}
            currentKey={current?.key}
            onSelect={selectItem}
            onMore={nextResults} />
        {:else}
          {#if items.length === 0}
            <p class="text-sm text-muted-foreground p-4">
              {filter_tags.length ? `Nothing here carries ${filter_tags.join(' and ')}.` : 'Nothing here yet.'}
            </p>
          {/if}
          {#each items as item (item.key)}
            <FieldItemCard {item} selected={current?.key === item.key} onSelect={selectItem} />
          {/each}
        {/if}
      </div>

      <div class="lg:col-span-2">
        {#if current}
          <div class="mb-3">
            {#key current.key}
              <FieldTagEditor accountId={account.id} itemKey={current.key} tags={current.tags || []} allTags={tags} />
            {/key}
          </div>
        {/if}
        {#if current?.kind === 'file'}
          <FieldFileViewer file={current} link={fieldItemLink(account.id, current.key)} onDelete={deleteFile} />
        {:else if current?.kind === 'recording'}
          {#key current.key}
            <RecordingViewer recording={current} />
          {/key}
        {:else if current?.kind === 'note'}
          <div class="mb-2 flex justify-end gap-1">
            <Button size="sm" variant="ghost" onclick={() => (historyOpen = true)} data-testid="note-history-open">
              History
            </Button>
            <Button size="sm" variant="ghost" onclick={copyNoteLink}>Copy link</Button>
            <Button size="sm" variant="ghost" onclick={deleteNote}>Delete note</Button>
          </div>
          <WhiteboardViewer
            selected={{ ...current, name: current.title }}
            {editing}
            bind:editContent
            {conflict}
            {saving}
            onStartEditing={startEditing}
            onCancelEditing={cancelEditing}
            onSave={saveNote}
            onUseServerVersion={useServerVersion}
            onKeepMyVersion={keepMyVersion} />
        {:else}
          <Card.Root>
            <Card.Content class="py-16 text-center text-muted-foreground">Choose something on the left.</Card.Content>
          </Card.Root>
        {/if}
      </div>
    </div>
  {/if}
</div>

<Dialog.Root bind:open={uploadOpen}>
  <Dialog.Content class="sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title>Add a file to the Field</Dialog.Title>
      <Dialog.Description>{sharedLine} {#if summaries_enabled}<SummariesNotice kind="file" />{/if}</Dialog.Description>
    </Dialog.Header>
    <form onsubmit={submitUpload} class="space-y-4">
      <div class="space-y-1">
        <Label for="field-file">File (up to {max_file_label})</Label>
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
      {#if uploadError}
        <p class="text-sm text-destructive" role="alert">{uploadError}</p>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="ghost" onclick={() => (uploadOpen = false)}>Cancel</Button>
        <Button type="submit" disabled={!uploadFile || uploadTooLarge || uploading}>
          {uploading ? 'Uploading…' : 'Add to the Field'}
        </Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>

<RecordingUploadDialog
  bind:open={recordingOpen}
  accountId={account.id}
  allowance={recording_allowance}
  maxBytes={max_recording_bytes}
  maxLabel={max_recording_label}
  suggestionsEnabled={suggestions_enabled}
  summariesEnabled={summaries_enabled}
  {sharedLine} />

<Dialog.Root bind:open={noteOpen}>
  <Dialog.Content class="sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title>New note</Dialog.Title>
      <Dialog.Description>{sharedLine} Residents can read and edit notes.</Dialog.Description>
    </Dialog.Header>
    <form onsubmit={submitNote} class="space-y-4">
      <div class="space-y-1">
        <Label for="note-name">Name</Label>
        <Input id="note-name" bind:value={noteName} maxlength={100} required />
      </div>
      <div class="space-y-1">
        <Label for="note-content">Note <span class="text-muted-foreground">(Markdown)</span></Label>
        <textarea
          id="note-content"
          bind:value={noteContent}
          rows="8"
          class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm font-mono"></textarea>
      </div>
      {#if noteError}
        <p class="text-sm text-destructive" role="alert">{noteError}</p>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="ghost" onclick={() => (noteOpen = false)}>Cancel</Button>
        <Button type="submit" disabled={!noteName.trim() || creatingNote}>Create note</Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>

<FieldTagManager bind:open={tagsOpen} accountId={account.id} {tags} onChanged={tagChanged} />

<NoteHistory bind:open={historyOpen} accountId={account.id} note={current?.kind === 'note' ? current : null} />
