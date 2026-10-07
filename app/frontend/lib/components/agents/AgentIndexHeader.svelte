<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Plus, GithubLogo, Archive } from 'phosphor-svelte';

  // The button's default is always a brand-new resident. The other ways in
  // (bring one from GitHub, import an archive) appear as a menu when the
  // pointer rests on the button, or on the first tap on a touch screen.
  let { onCreate, githubImportUrl = null, archiveImportUrl = null } = $props();

  let hasAlternatives = $derived(Boolean(githubImportUrl || archiveImportUrl));
  let open = $state(false);
  let wrapper = $state(null);
  let lastPointerType = 'mouse';
  let closeTimer = null;

  function show() {
    clearTimeout(closeTimer);
    if (hasAlternatives) open = true;
  }

  function hideSoon() {
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => (open = false), 150);
  }

  function handleClick(event) {
    // On touch there is no hover, so the first tap reveals the choices and
    // the "New resident" item in the menu keeps the default one tap away.
    if (hasAlternatives && lastPointerType === 'touch' && !open) {
      event.preventDefault();
      open = true;
      return;
    }
    open = false;
    onCreate?.();
  }

  function handleOutside(event) {
    if (open && wrapper && !wrapper.contains(event.target)) open = false;
  }

  function handleKeydown(event) {
    if (event.key === 'Escape') open = false;
  }

  function handleFocusOut(event) {
    if (wrapper && !wrapper.contains(event.relatedTarget)) open = false;
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
    onpointerenter={(e) => e.pointerType === 'mouse' && show()}
    onpointerleave={(e) => e.pointerType === 'mouse' && hideSoon()}
    onfocusin={show}
    onfocusout={handleFocusOut}>
    <Button
      onpointerdown={(e) => (lastPointerType = e.pointerType || 'mouse')}
      onclick={handleClick}
      aria-haspopup={hasAlternatives ? 'menu' : undefined}
      aria-expanded={hasAlternatives ? open : undefined}>
      <Plus class="mr-2 size-4" />
      New Resident
    </Button>
    {#if hasAlternatives && open}
      <div
        role="menu"
        aria-label="Other ways to add a resident"
        class="bg-popover text-popover-foreground absolute right-0 top-full z-50 mt-1 w-72 rounded-md border p-1 shadow-md">
        <button
          type="button"
          role="menuitem"
          class="hover:bg-accent focus:bg-accent flex w-full items-center gap-2 rounded-sm px-2 py-2 text-left text-sm outline-none"
          onclick={() => {
            open = false;
            onCreate?.();
          }}>
          <Plus class="size-4" />
          New resident
        </button>
        {#if githubImportUrl}
          <a
            role="menuitem"
            href={githubImportUrl}
            class="hover:bg-accent focus:bg-accent flex w-full items-center gap-2 rounded-sm px-2 py-2 text-sm outline-none">
            <GithubLogo class="size-4" />
            Bring an existing GitHub resident
          </a>
        {/if}
        {#if archiveImportUrl}
          <a
            role="menuitem"
            href={archiveImportUrl}
            class="hover:bg-accent focus:bg-accent flex w-full items-center gap-2 rounded-sm px-2 py-2 text-sm outline-none">
            <Archive class="size-4" />
            Import a resident archive
          </a>
        {/if}
      </div>
    {/if}
  </div>
</div>
