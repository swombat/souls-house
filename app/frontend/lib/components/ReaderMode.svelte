<script>
  // A full-screen reading view for one long document: a note, a transcript.
  // The page behind stays where it was; Escape or the × brings it back.
  // The caller passes the document as children, so whatever it renders inline
  // (markdown, transcript turns) it renders here the same way, just with the
  // whole window and a reading-width column.
  import { X } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { title, subtitle = null, onClose, children } = $props();

  let closeButton = $state(null);

  $effect(() => {
    const previous = document.body.style.overflow;
    const opener = document.activeElement;
    document.body.style.overflow = 'hidden';
    closeButton?.focus();
    return () => {
      document.body.style.overflow = previous;
      if (opener instanceof HTMLElement) opener.focus();
    };
  });

  function keydown(event) {
    if (event.key !== 'Escape' || event.defaultPrevented) return;
    event.preventDefault();
    onClose();
  }
</script>

<svelte:window onkeydown={keydown} />

<div
  class="fixed inset-0 z-50 flex flex-col bg-background"
  role="dialog"
  aria-modal="true"
  aria-label={title}
  data-testid="reader-mode">
  <div class="flex items-start justify-between gap-4 border-b border-border px-4 py-3 sm:px-6">
    <div class="min-w-0">
      <h2 class="font-semibold text-lg truncate">{title}</h2>
      {#if subtitle}
        <p class="text-xs text-muted-foreground truncate">{subtitle}</p>
      {/if}
    </div>
    <Button
      bind:ref={closeButton}
      variant="ghost"
      size="icon"
      onclick={onClose}
      aria-label="Close reader"
      title="Close (Esc)"
      data-testid="reader-mode-close">
      <X class="size-5" />
    </Button>
  </div>
  <div class="flex-1 overflow-y-auto">
    <div class="mx-auto w-full max-w-3xl px-4 py-8 sm:px-8 sm:py-12 text-[1.0625rem] leading-relaxed">
      {@render children()}
    </div>
  </div>
</div>
