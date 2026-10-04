<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import VisualTagIcon from '$lib/components/chat/VisualTagIcon.svelte';
  import VisualTagIconBrowser from './VisualTagIconBrowser.svelte';
  import { visualTagColour } from '$lib/visual-tags';

  let { accountId, tag = null, iconOptions = [], colourOptions = [], canManage = false, onDone = () => {} } = $props();
  const formId = $props.id();
  let label = $state(tag?.label || '');
  let icon = $state(tag?.icon || 'ChatCircle');
  let colour = $state(tag?.colour || 'slate');
  let saving = $state(false);
  let errors = $state({});
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
          onDone();
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
      onSuccess: onDone,
      onFinish: () => (saving = false),
    });
  }
</script>

<form
  onsubmit={submit}
  class="flex min-h-0 flex-1 flex-col gap-4"
  aria-label={tag ? `Edit ${tag.label}` : 'Add visual tag'}>
  <div class="grid min-h-0 flex-1 grid-rows-[auto_minmax(160px,1fr)] gap-5 sm:grid-cols-[220px_1fr] sm:grid-rows-1">
    <div class="space-y-4">
      <div class="hidden rounded-xl border bg-muted/20 p-3 sm:block" aria-label="Tag preview">
        <p class="mb-3 text-xs text-muted-foreground">In the discussion list</p>
        <div class="flex items-center gap-2 rounded-md bg-background px-2 py-3 text-sm">
          <VisualTagIcon {icon} size={16} class={`shrink-0 ${visualTagColour(colour)}`} />
          <span class="truncate">A conversation title</span>
        </div>
        <p class="mt-2 break-words text-xs text-muted-foreground">{label || 'New visual tag'}</p>
      </div>
      <div class="space-y-2">
        <Label for={`${formId}-label`}>Label</Label>
        <Input
          id={`${formId}-label`}
          bind:value={label}
          placeholder="e.g. Experiments"
          maxlength={80}
          required
          disabled={!canManage || saving} />
      </div>
      <fieldset disabled={!canManage || saving}>
        <legend class="mb-2 text-sm font-medium">Colour</legend>
        <div class="flex flex-wrap gap-1">
          {#each colourOptions as option}
            <button
              type="button"
              aria-label={`Colour: ${option}`}
              aria-pressed={colour === option}
              title={option}
              onclick={() => (colour = option)}
              class="flex h-9 w-9 items-center justify-center rounded-full focus-visible:outline focus-visible:outline-2 {colour ===
              option
                ? 'ring-2 ring-primary ring-offset-2 ring-offset-background'
                : 'hover:bg-muted'} {visualTagColour(option)}">
              <span class="h-6 w-6 rounded-full bg-current"></span>
            </button>
          {/each}
        </div>
      </fieldset>
    </div>
    <VisualTagIconBrowser options={iconOptions} bind:value={icon} {colour} disabled={!canManage || saving} />
  </div>
  {#if Object.keys(errors).length}
    <p role="alert" class="text-sm text-destructive">{Object.values(errors).flat().join('. ')}</p>
  {/if}
  {#if canManage}
    <div class="flex shrink-0 items-center justify-between gap-2 border-t pt-4">
      <div>
        {#if tag}<Button
            type="button"
            size="sm"
            variant="ghost"
            class="text-destructive"
            onclick={remove}
            disabled={saving}>Remove tag</Button
          >{/if}
      </div>
      <div class="flex gap-2">
        <Button type="button" size="sm" variant="outline" onclick={onDone} disabled={saving}>Cancel</Button>
        <Button type="submit" size="sm" disabled={saving || !label.trim() || !changed}>
          {saving ? 'Saving…' : tag ? 'Save changes' : 'Add tag'}
        </Button>
      </div>
    </div>
  {/if}
</form>
