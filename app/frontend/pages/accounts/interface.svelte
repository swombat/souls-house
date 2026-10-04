<script>
  import { page } from '@inertiajs/svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import VisualTagForm from '$lib/components/accounts/VisualTagForm.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Plus, PencilSimple } from 'phosphor-svelte';
  import VisualTagIcon from '$lib/components/chat/VisualTagIcon.svelte';
  import { visualTagColour } from '$lib/visual-tags';
  import { createDynamicSync } from '$lib/use-sync';

  let { account, visual_tags = [], can_manage = false, icon_options = [], colour_options = [] } = $props();
  const updateSync = createDynamicSync();
  let editing = $state(null);
  let open = $state(false);
  function edit(tag = null) {
    editing = tag;
    open = true;
  }
  $effect(() => {
    updateSync({ [`Account:${account.id}`]: 'visual_tags' });
  });
</script>

<svelte:head><title>Interface · {account.name}</title></svelte:head>

<AccountSettingsLayout {account} active="interface" title="Interface" description="How this account looks and feels.">
  <FlashMessages flash={$page.props.flash} />
  <section class="space-y-4" aria-labelledby="visual-tags-heading">
    <div class="flex items-start justify-between gap-4">
      <div class="space-y-2">
        <h2 id="visual-tags-heading" class="text-xl font-semibold">Visual tags</h2>
        <p class="text-sm text-muted-foreground">
          A little colour for your conversations. Choose a tag beside any thread title.
        </p>
        {#if !can_manage}<p class="text-sm text-muted-foreground">
            You do not have permission to edit this account’s palette.
          </p>{/if}
      </div>
      {#if can_manage}
        <Button size="sm" class="shrink-0" onclick={() => edit()}><Plus size={16} /> Add tag</Button>
      {/if}
    </div>
    <div class="grid gap-2 sm:grid-cols-2" aria-label="Visual tag palette">
      {#each visual_tags as tag (tag.id)}
        <button
          type="button"
          disabled={!can_manage}
          onclick={() => edit(tag)}
          aria-label={`Edit ${tag.label}`}
          class="group flex min-w-0 items-center gap-3 rounded-xl border bg-background p-3 text-left transition-colors enabled:hover:bg-muted/50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring">
          <span class="flex h-11 w-11 shrink-0 items-center justify-center rounded-lg bg-muted/50">
            <VisualTagIcon icon={tag.icon} size={26} class={visualTagColour(tag.colour)} />
          </span>
          <span class="min-w-0 flex-1 break-words text-sm font-medium">{tag.label}</span>
          {#if can_manage}<PencilSimple
              size={16}
              class="shrink-0 text-muted-foreground/50 group-hover:text-foreground" />{/if}
        </button>
      {:else}
        <p class="text-sm text-muted-foreground">No visual tags yet.</p>
      {/each}
    </div>
    <p class="text-xs leading-relaxed text-muted-foreground">
      Shared across this account. Editing a tag updates every thread using it; removing it leaves the threads intact.
      Tags never change notifications or access.
    </p>
  </section>
</AccountSettingsLayout>

<Dialog.Root bind:open>
  <Dialog.Content class="flex h-[min(760px,90dvh)] max-w-[calc(100%-1rem)] flex-col sm:max-w-3xl">
    <Dialog.Header>
      <Dialog.Title>{editing ? 'Edit visual tag' : 'Create a visual tag'}</Dialog.Title>
      <Dialog.Description
        >Pick an icon by sight. Search the full Phosphor library, then make it yours.</Dialog.Description>
    </Dialog.Header>
    {#if open}
      <VisualTagForm
        accountId={account.id}
        tag={editing ? visual_tags.find((tag) => tag.id === editing.id) || editing : null}
        iconOptions={icon_options}
        colourOptions={colour_options}
        canManage={can_manage}
        onDone={() => (open = false)} />
    {/if}
  </Dialog.Content>
</Dialog.Root>
