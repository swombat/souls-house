<script>
  // The guard on every Voices action that throws away learned prints and the
  // samples people reviewed. None of it can be undone, so the dialog says
  // what goes and, when confirmed samples are among it, asks for the word
  // typed out. A tap by mistake can't get through (Daniel, 2026-10-22,
  // gjDoBe).
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';

  const WORD = 'FORGET';

  let {
    open = $bindable(false),
    title,
    losses = [],
    keeps = '',
    confirmLabel = 'Forget',
    requireWord = false,
    onconfirm,
  } = $props();

  let typed = $state('');
  const ready = $derived(!requireWord || typed.trim().toUpperCase() === WORD);

  $effect(() => {
    if (!open) typed = '';
  });

  function confirm(event) {
    event?.preventDefault();
    if (!ready) return;
    open = false;
    onconfirm?.();
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="max-w-md" data-testid="forget-voice-dialog">
    <Dialog.Header>
      <Dialog.Title>{title}</Dialog.Title>
      <Dialog.Description>This can't be undone.</Dialog.Description>
    </Dialog.Header>
    <form class="space-y-3 text-sm" onsubmit={confirm}>
      {#if losses.length}
        <div>
          <p class="font-medium">Deleted:</p>
          <ul class="list-disc pl-5 text-muted-foreground">
            {#each losses as loss}<li>{loss}</li>{/each}
          </ul>
        </div>
      {/if}
      {#if keeps}<p><span class="font-medium">Kept:</span> {keeps}</p>{/if}
      {#if requireWord}
        <label class="block space-y-1">
          <span>Type <strong>{WORD}</strong> to confirm</span>
          <Input
            bind:value={typed}
            autocomplete="off"
            autocapitalize="characters"
            spellcheck="false"
            aria-label="Type {WORD} to confirm"
            data-testid="forget-voice-word" />
        </label>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="outline" onclick={() => (open = false)}>Cancel</Button>
        <Button type="submit" variant="destructive" disabled={!ready} data-testid="forget-voice-confirm"
          >{confirmLabel}</Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>
