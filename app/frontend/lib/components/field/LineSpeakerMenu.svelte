<script>
  import { CaretDown, Plus } from 'phosphor-svelte';

  // The speaker's name over a transcript line, as a control: the transcriber
  // sometimes hears one person's sentence as another's. Click (or tap) opens
  // "Who said this?" with the other people in the recording and "Someone
  // new". `onPick(speakerId | 'new')` resolves to {ok, error}.
  let { name, muted = false, choices = [], finePointer = true, disabled = false, onPick } = $props();

  let open = $state(false);
  let root = $state(null);
  let moving = $state(false);
  let error = $state('');

  function toggle() {
    if (disabled) return;
    error = '';
    open = !open;
  }

  async function pick(speakerId) {
    open = false;
    moving = true;
    error = '';
    let result;
    try {
      result = await onPick(speakerId);
    } catch {
      result = { ok: false };
    } finally {
      moving = false;
    }
    if (!result?.ok) error = result?.error || "That didn't change. Please try again.";
  }

  function windowClick(event) {
    // Its own menu only: opening another line's closes this one.
    if (open && !root?.contains(event.target)) open = false;
  }

  function keydown(event) {
    if (open && event.key === 'Escape') open = false;
  }
</script>

<svelte:window onclick={windowClick} onkeydown={keydown} />

<div class="relative inline-block" data-speaker-menu bind:this={root}>
  <button
    type="button"
    class="group/speaker inline-flex items-center gap-1 rounded -mx-1 px-1 text-sm font-semibold hover:bg-muted disabled:opacity-50 {muted
      ? 'text-muted-foreground'
      : ''} {open ? 'bg-muted' : ''}"
    aria-haspopup="menu"
    aria-expanded={open}
    title="Someone else said this?"
    disabled={disabled || moving}
    data-testid="line-speaker"
    onclick={toggle}>
    {name}
    <CaretDown
      class="size-3 text-muted-foreground transition-opacity {finePointer && !open
        ? 'opacity-0 group-hover:opacity-100 group-hover/speaker:opacity-100 group-focus-visible/speaker:opacity-100'
        : ''}" />
    {#if moving}<span class="font-normal text-xs text-muted-foreground">Moving…</span>{/if}
  </button>
  {#if open}
    <div
      role="menu"
      class="absolute left-0 top-full z-20 mt-1 min-w-48 max-h-72 overflow-y-auto rounded-md border bg-popover py-1 text-sm shadow-md"
      data-testid="line-speaker-menu">
      <p class="px-3 py-1.5 text-xs text-muted-foreground">Who said this?</p>
      {#each choices as choice (choice.id)}
        <button
          type="button"
          role="menuitem"
          class="block w-full px-3 py-2 text-left hover:bg-muted"
          onclick={() => pick(choice.id)}>{choice.name}</button>
      {/each}
      <button
        type="button"
        role="menuitem"
        class="flex w-full items-center gap-1.5 border-t px-3 py-2 text-left text-muted-foreground hover:bg-muted hover:text-foreground"
        data-testid="line-speaker-new"
        onclick={() => pick('new')}>
        <Plus class="size-4" /> Someone new
      </button>
    </div>
  {/if}
</div>
{#if error}
  <p class="text-xs text-destructive" data-testid="line-speaker-error">{error}</p>
{/if}
