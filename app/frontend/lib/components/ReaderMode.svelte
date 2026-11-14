<script>
  // A full-screen reading view for one long document: a note, a transcript.
  // The children are always mounted here, once. Closed, they render inline
  // with no chrome. Open, the same DOM moves to the end of <body> under a
  // header with a ×, and everything else on the page is made inert, so Tab
  // can't wander behind it. Moving the nodes rather than mounting a second
  // copy keeps the children's own state (a half-written transcript line, a
  // failed save's text) across opening and closing.
  import { tick } from 'svelte';
  import { X } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { open = false, title, subtitle = null, onClose, children } = $props();

  let root = $state(null);

  $effect(() => {
    if (!open || !root) return;
    const opener = document.activeElement;
    const placeholder = document.createComment('reader-mode');
    root.before(placeholder);
    document.body.appendChild(root);

    const madeInert = [];
    for (const el of document.body.children) {
      if (el === root || el.hasAttribute('inert')) continue;
      el.setAttribute('inert', '');
      madeInert.push(el);
    }
    const overflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    tick().then(() => root?.querySelector('[data-reader-close]')?.focus());

    return () => {
      for (const el of madeInert) el.removeAttribute('inert');
      document.body.style.overflow = overflow;
      if (placeholder.parentNode) placeholder.replaceWith(root);
      else root.remove();
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
    };
  });

  function keydown(event) {
    if (!open || event.key !== 'Escape' || event.defaultPrevented) return;
    event.preventDefault();
    onClose();
  }
</script>

<svelte:window onkeydown={keydown} />

<div
  bind:this={root}
  class={open ? 'fixed inset-0 z-50 flex flex-col bg-background' : 'contents'}
  role={open ? 'dialog' : undefined}
  aria-modal={open ? 'true' : undefined}
  aria-label={open ? title : undefined}
  data-testid={open ? 'reader-mode' : undefined}>
  {#if open}
    <div class="flex items-start justify-between gap-4 border-b border-border px-4 py-3 sm:px-6">
      <div class="min-w-0">
        <h2 class="font-semibold text-lg truncate">{title}</h2>
        {#if subtitle}
          <p class="text-xs text-muted-foreground truncate">{subtitle}</p>
        {/if}
      </div>
      <Button
        data-reader-close
        variant="ghost"
        size="icon"
        onclick={onClose}
        aria-label="Close reader"
        title="Close (Esc)"
        data-testid="reader-mode-close">
        <X class="size-5" />
      </Button>
    </div>
  {/if}
  <div class={open ? 'flex-1 overflow-y-auto' : 'contents'}>
    <div
      class={open
        ? 'mx-auto w-full max-w-3xl px-4 py-8 sm:px-8 sm:py-12 text-[1.0625rem] leading-relaxed'
        : 'contents'}>
      {@render children()}
    </div>
  </div>
</div>
