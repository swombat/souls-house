<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Switch } from '$lib/components/shadcn/switch';
  import VisualTagIcon from '$lib/components/chat/VisualTagIcon.svelte';
  import VisualTagIconBrowser from './VisualTagIconBrowser.svelte';
  import { visualTagColour } from '$lib/visual-tags';

  let { accountId, tag = null, iconOptions = [], colourOptions = [], canManage = false, onDone = () => {} } = $props();
  const formId = $props.id();
  let label = $state(tag?.label || '');
  let icon = $state(tag?.icon || 'ChatCircle');
  let colour = $state(tag?.colour || 'slate');
  let pinsToTop = $state(Boolean(tag?.pins_to_top));
  let hidesFromList = $state(Boolean(tag?.hides_from_list));
  let saving = $state(false);
  let errors = $state({});
  const changed = $derived(
    !tag ||
      label !== tag.label ||
      icon !== tag.icon ||
      colour !== tag.colour ||
      pinsToTop !== Boolean(tag.pins_to_top) ||
      hidesFromList !== Boolean(tag.hides_from_list)
  );

  // Refresh an untouched form when another account member edits the palette.
  let source = $state(tag);
  $effect(() => {
    if (
      source?.label !== tag?.label ||
      source?.icon !== tag?.icon ||
      source?.colour !== tag?.colour ||
      source?.pins_to_top !== tag?.pins_to_top ||
      source?.hides_from_list !== tag?.hides_from_list
    ) {
      if (
        label === source?.label &&
        icon === source?.icon &&
        colour === source?.colour &&
        pinsToTop === Boolean(source?.pins_to_top) &&
        hidesFromList === Boolean(source?.hides_from_list)
      ) {
        label = tag?.label || '';
        icon = tag?.icon || 'ChatCircle';
        colour = tag?.colour || 'slate';
        pinsToTop = Boolean(tag?.pins_to_top);
        hidesFromList = Boolean(tag?.hides_from_list);
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
      {
        visual_tag: {
          label: label.trim(),
          icon,
          colour,
          pins_to_top: tag?.pinned ? true : pinsToTop,
          hides_from_list: tag?.pinned ? false : hidesFromList,
        },
      },
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
  class="flex flex-col gap-4 sm:min-h-0 sm:flex-1"
  aria-label={tag ? `Edit ${tag.label}` : 'Add visual tag'}>
  <div class="flex flex-col gap-5 sm:grid sm:min-h-0 sm:flex-1 sm:grid-cols-[220px_1fr] sm:grid-rows-1">
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
          disabled={!canManage || saving || tag?.pinned} />
        {#if tag?.pinned}
          <p class="text-xs text-muted-foreground">
            Every account has a Pin tag. Pinned conversations stay at the top of the list. You can change its colour and
            icon, but not its name, and it can't be removed.
          </p>
        {/if}
      </div>
      <div class="space-y-1">
        <label class="flex items-center justify-between gap-3 text-sm font-medium">
          <span>Keep at the top</span>
          <Switch
            aria-label="Keep conversations with this tag at the top"
            data-testid="visual-tag-pins-to-top"
            checked={tag?.pinned ? true : pinsToTop}
            disabled={!canManage || saving || tag?.pinned}
            onCheckedChange={(value) => {
              pinsToTop = value;
              if (value) hidesFromList = false;
            }} />
        </label>
        <p class="text-xs text-muted-foreground">
          {tag?.pinned
            ? 'The Pin tag always keeps its conversations at the top.'
            : 'Conversations with this tag stay at the top of the list, with pinned ones.'}
        </p>
      </div>
      {#if !tag?.pinned}
        <div class="space-y-1">
          <label class="flex items-center justify-between gap-3 text-sm font-medium">
            <span>Hide from the list</span>
            <Switch
              aria-label="Hide conversations with this tag from the list"
              data-testid="visual-tag-hides-from-list"
              checked={hidesFromList}
              disabled={!canManage || saving}
              onCheckedChange={(value) => {
                hidesFromList = value;
                if (value) pinsToTop = false;
              }} />
          </label>
          <p class="text-xs text-muted-foreground">
            Conversations with this tag leave the list without being archived, and come back when the tag comes off.
            Filter → Hidden shows them.
          </p>
        </div>
      {/if}
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
    <div
      class="sticky bottom-0 z-10 -mx-4 flex shrink-0 items-center justify-between gap-2 border-t bg-background px-4 py-3 sm:static sm:mx-0 sm:px-0 sm:pb-0 sm:pt-4">
      <div>
        {#if tag && !tag.pinned}<Button
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
