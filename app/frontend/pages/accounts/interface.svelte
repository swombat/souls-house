<script>
  import { page } from '@inertiajs/svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import VisualTagForm from '$lib/components/accounts/VisualTagForm.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { createDynamicSync } from '$lib/use-sync';

  let { account, visual_tags = [], can_manage = false, icon_options = [], colour_options = [] } = $props();
  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`Account:${account.id}`]: 'visual_tags' });
  });
</script>

<svelte:head><title>Interface · {account.name}</title></svelte:head>

<AccountSettingsLayout {account} active="interface" title="Interface" description="How this account looks and feels.">
  <FlashMessages flash={$page.props.flash} />
  <section class="space-y-4" aria-labelledby="visual-tags-heading">
    <div class="space-y-2">
      <h2 id="visual-tags-heading" class="text-xl font-semibold">Visual tags</h2>
      <p class="text-sm text-muted-foreground">
        A coloured icon beside a conversation title. Click or tap it in the discussion list to choose a tag. Tags are
        shared by everyone in this account; they do not change notifications or access.
      </p>
      <p class="text-sm text-muted-foreground">
        Editing a tag updates every conversation using it. Removing one leaves those conversations with no tag.
      </p>
      {#if !can_manage}<p class="text-sm text-muted-foreground">
          You do not have permission to edit this account’s palette.
        </p>{/if}
    </div>
    {#each visual_tags as tag (tag.id)}
      <VisualTagForm
        accountId={account.id}
        {tag}
        iconOptions={icon_options}
        colourOptions={colour_options}
        canManage={can_manage} />
    {:else}
      <p class="text-sm text-muted-foreground">No visual tags yet.</p>
    {/each}
    {#if can_manage}
      <h3 class="pt-2 font-medium">Add a visual tag</h3>
      <VisualTagForm
        accountId={account.id}
        iconOptions={icon_options}
        colourOptions={colour_options}
        canManage={can_manage} />
    {/if}
  </section>
</AccountSettingsLayout>
