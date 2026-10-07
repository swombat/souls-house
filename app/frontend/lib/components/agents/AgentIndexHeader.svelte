<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Plus, GithubLogo, Archive } from 'phosphor-svelte';

  // The button's default is always a brand-new resident. The other ways in
  // (bring one from GitHub, import an archive) appear in a small panel when
  // the mouse rests on the button, when the keyboard reaches it, or on the
  // first tap on a touch screen. The panel is a disclosure of ordinary links,
  // not an ARIA menu, so Tab and Enter work the way they do everywhere else.
  let { onCreate, githubImportUrl = null, archiveImportUrl = null } = $props();

  const panelId = 'new-resident-alternatives';
  let hasAlternatives = $derived(Boolean(githubImportUrl || archiveImportUrl));
  let open = $state(false);
  let wrapper = $state(null);
  let trigger = $state(null);
  let closeTimer = null;

  // Set at pointerdown, read at click. A native tap focuses the button
  // between the two, so the open state must be captured before that focus.
  let pointerType = null;
  let openAtPointerDown = false;
  let pointerInProgress = false;
  // Set while we move focus back to the trigger on Escape, so that focus
  // doesn't reopen the panel we just closed.
  let suppressFocusOpen = false;

  function show() {
    clearTimeout(closeTimer);
    if (hasAlternatives) open = true;
  }

  function hideSoon() {
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => (open = false), 150);
  }

  function handlePointerDown(event) {
    pointerType = event.pointerType || 'mouse';
    openAtPointerDown = open;
    pointerInProgress = true;
  }

  function handleClick(event) {
    const type = pointerInProgress ? pointerType : 'keyboard';
    pointerInProgress = false;
    // On touch there is no hover, so the first tap reveals the choices. The
    // first link in the panel is "Start a new resident", so the default is
    // still one tap away.
    if (hasAlternatives && type === 'touch' && !openAtPointerDown) {
      event.preventDefault();
      open = true;
      return;
    }
    open = false;
    onCreate?.();
  }

  function handleFocusIn(event) {
    if (suppressFocusOpen) return;
    // Pointer focus is handled by hover (mouse) or the tap logic (touch);
    // only keyboard focus, which browsers mark :focus-visible, opens it here.
    if (event.target === trigger && !isFocusVisible(event.target)) return;
    show();
  }

  function isFocusVisible(element) {
    try {
      return element.matches(':focus-visible');
    } catch {
      return false;
    }
  }

  function handleFocusOut(event) {
    if (wrapper && !wrapper.contains(event.relatedTarget)) open = false;
  }

  function handleOutside(event) {
    if (open && wrapper && !wrapper.contains(event.target)) open = false;
  }

  function handleKeydown(event) {
    if (event.key !== 'Escape' || !open) return;
    const focusInside = wrapper?.contains(document.activeElement);
    open = false;
    if (focusInside && document.activeElement !== trigger) {
      suppressFocusOpen = true;
      trigger?.focus();
      suppressFocusOpen = false;
    }
  }
</script>

<svelte:window onpointerdown={handleOutside} onkeydown={handleKeydown} />

<div class="flex items-center justify-between mb-8">
  <div>
    <h1 class="text-3xl font-bold">Residents</h1>
    <p class="text-muted-foreground mt-1">Create and care for persistent hosted AI partners</p>
  </div>
  <div
    class="relative flex gap-2"
    bind:this={wrapper}
    role="group"
    aria-label="Add a resident"
    onpointerenter={(e) => e.pointerType === 'mouse' && show()}
    onpointerleave={(e) => e.pointerType === 'mouse' && hideSoon()}
    onfocusin={handleFocusIn}
    onfocusout={handleFocusOut}>
    <Button
      bind:ref={trigger}
      onpointerdown={handlePointerDown}
      onpointercancel={() => (pointerInProgress = false)}
      onclick={handleClick}
      aria-controls={hasAlternatives ? panelId : undefined}
      aria-expanded={hasAlternatives ? open : undefined}>
      <Plus class="mr-2 size-4" />
      New Resident
    </Button>
    {#if hasAlternatives && open}
      <div
        id={panelId}
        class="bg-popover text-popover-foreground absolute right-0 top-full z-50 mt-1 w-72 rounded-md border p-1 shadow-md">
        <button
          type="button"
          class="hover:bg-accent focus-visible:bg-accent flex w-full items-center gap-2 rounded-sm px-2 py-2 text-left text-sm outline-none"
          onclick={() => {
            open = false;
            onCreate?.();
          }}>
          <Plus class="size-4" />
          Start a new resident
        </button>
        {#if githubImportUrl}
          <a
            href={githubImportUrl}
            class="hover:bg-accent focus-visible:bg-accent flex w-full items-center gap-2 rounded-sm px-2 py-2 text-sm outline-none">
            <GithubLogo class="size-4" />
            Bring an existing GitHub resident
          </a>
        {/if}
        {#if archiveImportUrl}
          <a
            href={archiveImportUrl}
            class="hover:bg-accent focus-visible:bg-accent flex w-full items-center gap-2 rounded-sm px-2 py-2 text-sm outline-none">
            <Archive class="size-4" />
            Import a resident archive
          </a>
        {/if}
      </div>
    {/if}
  </div>
</div>
