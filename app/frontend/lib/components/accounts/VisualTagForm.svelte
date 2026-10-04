<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { visualTagIcon, visualTagColour, iconLabel } from '$lib/visual-tags';

  let { accountId, tag = null, iconOptions = [], colourOptions = [], canManage = false } = $props();
  const formId = $props.id();
  let label = $state(tag?.label || '');
  let icon = $state(tag?.icon || 'ChatCircle');
  let colour = $state(tag?.colour || 'slate');
  let saving = $state(false);
  let errors = $state({});
  const Icon = $derived(visualTagIcon(icon));
  const changed = $derived(!tag || label !== tag.label || icon !== tag.icon || colour !== tag.colour);

  // Refresh an untouched form when another account member edits the palette.
  let source = $state(tag);
  $effect(() => {
    if (source?.label !== tag?.label || source?.icon !== tag?.icon || source?.colour !== tag?.colour) {
      if (label === source?.label && icon === source?.icon && colour === source?.colour) {
        label = tag?.label || '';
        icon = tag?.icon || 'ChatCircle';
        colour = tag?.colour || 'slate';
      }
      source = tag;
    }
  });

  function submit(event) {
    event.preventDefault();
    if (!canManage || saving || !label.trim()) return;
    saving = true;
    errors = {};
    const path = `/accounts/${accountId}/visual_tags${tag ? `/${tag.id}` : ''}`;
    router[tag ? 'patch' : 'post'](
      path,
      { visual_tag: { label: label.trim(), icon, colour } },
      {
        preserveScroll: true,
        onError: (value) => (errors = value),
        onSuccess: () => {
          if (!tag) {
            label = '';
            icon = 'ChatCircle';
            colour = 'slate';
          }
        },
        onFinish: () => (saving = false),
      }
    );
  }

  function remove() {
    if (!canManage || saving || !confirm(`Remove “${tag.label}”? Conversations using it will have no tag.`)) return;
    saving = true;
    errors = {};
    router.delete(`/accounts/${accountId}/visual_tags/${tag.id}`, {
      preserveScroll: true,
      onError: (value) => (errors = value),
      onFinish: () => (saving = false),
    });
  }
</script>

<form
  onsubmit={submit}
  class="space-y-3 rounded-lg border border-border p-4"
  aria-label={tag ? `Edit ${tag.label}` : 'Add visual tag'}>
  <div class="flex items-center gap-2 text-sm font-medium">
    <Icon size={20} class={visualTagColour(colour)} weight="duotone" />
    <span class="break-words">{label || 'New visual tag'}</span>
  </div>
  <div class="grid gap-3 sm:grid-cols-3">
    <div class="space-y-1">
      <Label for={`${formId}-label`}>Label</Label>
      <Input id={`${formId}-label`} bind:value={label} maxlength={80} required disabled={!canManage || saving} />
    </div>
    <div class="space-y-1">
      <Label for={`${formId}-icon`}>Icon</Label>
      <select
        id={`${formId}-icon`}
        bind:value={icon}
        disabled={!canManage || saving}
        class="h-9 w-full rounded-md border border-input bg-background px-2 text-sm">
        {#each iconOptions as option}<option value={option}>{iconLabel(option)}</option>{/each}
      </select>
    </div>
    <div class="space-y-1">
      <Label for={`${formId}-colour`}>Colour</Label>
      <select
        id={`${formId}-colour`}
        bind:value={colour}
        disabled={!canManage || saving}
        class="h-9 w-full rounded-md border border-input bg-background px-2 text-sm">
        {#each colourOptions as option}<option value={option}>{option[0].toUpperCase() + option.slice(1)}</option
          >{/each}
      </select>
    </div>
  </div>
  {#if Object.keys(errors).length}
    <p role="alert" class="text-sm text-destructive">{Object.values(errors).flat().join('. ')}</p>
  {/if}
  {#if canManage}
    <div class="flex flex-wrap gap-2">
      <Button type="submit" size="sm" disabled={saving || !label.trim() || !changed}>
        {saving ? 'Saving…' : tag ? 'Save changes' : 'Add tag'}
      </Button>
      {#if tag}<Button type="button" size="sm" variant="outline" onclick={remove} disabled={saving}>Remove</Button>{/if}
    </div>
  {/if}
</form>
