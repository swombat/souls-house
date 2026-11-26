<script>
  // The ways into the Field, behind one Add button. On a phone the choices
  // open as a sheet from the bottom; from sm up, as a menu under the button.
  // Recording now and bringing in a recording sit together at the top, so
  // the two are easy to find and hard to confuse.
  import { Button, buttonVariants } from '$lib/components/shadcn/button/index.js';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import * as Drawer from '$lib/components/shadcn/drawer/index.js';
  import { cn } from '$lib/utils.js';
  import { FileArrowUp, Microphone, MusicNotes, NotePencil, Plus, Record } from 'phosphor-svelte';

  let { onFile, onNote, onRecordNow, onRecording, onSong } = $props();

  const choices = $derived([
    {
      key: 'record',
      testId: 'field-record-now',
      label: 'Record now',
      hint: 'Speak a voice note into the Field',
      icon: Record,
      run: onRecordNow,
    },
    {
      key: 'recording',
      testId: 'field-add-recording',
      label: 'Bring in a recording',
      hint: 'Upload audio or video you already have',
      icon: Microphone,
      run: onRecording,
    },
    {
      key: 'file',
      testId: 'field-add-file',
      label: 'File',
      hint: 'A document, an image, anything',
      icon: FileArrowUp,
      run: onFile,
    },
    {
      key: 'note',
      testId: 'field-new-note',
      label: 'Note',
      hint: 'Write something down',
      icon: NotePencil,
      run: onNote,
    },
    { key: 'song', testId: 'field-add-song', label: 'Song', hint: 'Share a song', icon: MusicNotes, run: onSong },
  ]);

  let phone = $state(false);
  let sheetOpen = $state(false);

  $effect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const query = window.matchMedia('(max-width: 639px)');
    if (!query) return;
    phone = query.matches;
    const change = (event) => (phone = event.matches);
    query.addEventListener?.('change', change);
    return () => query.removeEventListener?.('change', change);
  });

  // The menu or sheet closes first and hands focus back; the chosen dialog
  // opens on the next tick so the two don't fight over focus.
  function choose(choice) {
    sheetOpen = false;
    setTimeout(() => choice.run?.(), 0);
  }
</script>

{#if phone}
  <Button class="w-full" onclick={() => (sheetOpen = true)} data-testid="field-add">
    <Plus class="size-4" /> Add
  </Button>
  <!-- autoFocus: vaul defaults it off, which leaves keyboard focus behind the sheet. -->
  <Drawer.Root bind:open={sheetOpen} direction="bottom" autoFocus>
    <Drawer.Content data-testid="field-add-sheet">
      <Drawer.Header class="text-left">
        <Drawer.Title>Add to the Field</Drawer.Title>
        <Drawer.Description class="sr-only">Choose what to bring into the Field</Drawer.Description>
      </Drawer.Header>
      <div class="grid gap-1 px-2 pb-6">
        {#each choices as choice (choice.key)}
          <button
            type="button"
            class="flex items-center gap-3 rounded-md px-3 py-3 text-left hover:bg-muted active:bg-muted"
            onclick={() => choose(choice)}
            data-testid={choice.testId}>
            <choice.icon class="size-6 shrink-0 {choice.key === 'record' ? 'text-red-600' : ''}" />
            <span>
              <span class="block font-medium">{choice.label}</span>
              <span class="block text-xs text-muted-foreground">{choice.hint}</span>
            </span>
          </button>
          {#if choice.key === 'recording'}
            <div class="mx-3 my-1 border-t"></div>
          {/if}
        {/each}
      </div>
    </Drawer.Content>
  </Drawer.Root>
{:else}
  <DropdownMenu.Root>
    <DropdownMenu.Trigger class={cn(buttonVariants({ variant: 'default' }), 'gap-2')} data-testid="field-add">
      <Plus class="size-4" /> Add
    </DropdownMenu.Trigger>
    <DropdownMenu.Content class="w-72" align="end">
      {#each choices as choice (choice.key)}
        <DropdownMenu.Item class="items-start gap-3 py-2" onSelect={() => choose(choice)} data-testid={choice.testId}>
          <choice.icon class="mt-0.5 size-4 shrink-0 {choice.key === 'record' ? 'text-red-600' : ''}" />
          <span>
            <span class="block">{choice.label}</span>
            <span class="block text-xs text-muted-foreground">{choice.hint}</span>
          </span>
        </DropdownMenu.Item>
        {#if choice.key === 'recording'}
          <DropdownMenu.Separator />
        {/if}
      {/each}
    </DropdownMenu.Content>
  </DropdownMenu.Root>
{/if}
