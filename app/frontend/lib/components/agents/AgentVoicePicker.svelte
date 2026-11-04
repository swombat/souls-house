<script>
  import { onMount } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Label } from '$lib/components/shadcn/label';
  import { Check, Play, SpeakerSlash } from 'phosphor-svelte';

  // The resident's speaking voice: one of the standard ElevenLabs voices, or
  // none. Saved on its own (like the picture), so the tab's other fields are
  // not submitted with it.
  let { voice = null } = $props();

  let selected = $state(voice?.current_voice_id ?? '');
  let busy = $state(false);
  let error = $state(null);
  let previewSrc = $state(null);
  // Each Preview press gets a fresh audio element, so a repeat or a retry
  // after an error plays again instead of waiting on an element that has
  // already loaded (or already failed).
  let previewAttempt = $state(0);
  let previewLoading = $state(false);
  let previewError = $state(null);

  let voices = $state([]);
  let loading = $state(true);
  let unavailable = $state(false);

  // The list comes after the page draws, so a slow provider never holds up
  // the settings page.
  onMount(async () => {
    if (!voice?.voices_path) return;
    try {
      const response = await fetch(voice.voices_path, { headers: { Accept: 'application/json' } });
      const body = response.ok ? await response.json() : { unavailable: true };
      voices = body.voices ?? [];
      unavailable = Boolean(body.unavailable) || !response.ok;
    } catch {
      unavailable = true;
    } finally {
      loading = false;
    }
  });

  const current = $derived(voice?.current_voice_id ?? null);

  // The saved voice can change under the page (the resident chose one, or
  // another person did): follow it unless the person here has picked
  // something else they haven't saved yet.
  let lastSeenCurrent = voice?.current_voice_id ?? null;
  $effect(() => {
    const next = current;
    if (next === lastSeenCurrent) return;
    if ((selected || null) === lastSeenCurrent) selected = next ?? '';
    lastSeenCurrent = next;
  });
  const currentIsStandard = $derived(!current || voices.some((v) => v.voice_id === current));
  const chosen = $derived(voices.find((v) => v.voice_id === selected) ?? null);
  const changed = $derived((selected || null) !== current);

  function describe(v) {
    const labels = v.labels || {};
    return ['accent', 'age', 'gender', 'use_case']
      .map((key) => labels[key])
      .filter(Boolean)
      .map((part) => String(part).replaceAll('_', ' '))
      .join(', ');
  }

  // Each voice gets its own colour, stable across visits (a hash of its id),
  // so the list reads as a set of distinct voices rather than a column of text.
  function hue(id) {
    let h = 0;
    for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return h % 360;
  }

  function choose(id) {
    if (selected === id) return;
    selected = id;
    previewSrc = null;
    previewError = null;
    previewLoading = false;
  }

  let previewingId = $state(null);

  // Preview plays the given voice (and picks it, so Use this voice saves what
  // was just heard).
  function preview(id = chosen?.voice_id) {
    if (!id) return;
    choose(id);
    previewingId = id;
    previewError = null;
    previewLoading = true;
    previewSrc = voice.preview_path_template.replace('VOICE_ID', encodeURIComponent(id));
    previewAttempt += 1;
  }

  function save() {
    busy = true;
    error = null;
    router.patch(
      voice.update_path,
      { voice_id: selected || null },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: (page) => {
          const failed = page?.props?.errors?.voice_id;
          if (failed) error = failed;
        },
        onError: (errors) => {
          error = errors.voice_id || 'That didn’t work. Please try again.';
        },
        onFinish: () => {
          busy = false;
        },
      }
    );
  }
</script>

{#if voice}
  <div class="space-y-2" data-testid="agent-voice-picker">
    <Label id="agent-voice-label">ElevenLabs voice</Label>
    <p class="text-xs text-muted-foreground">
      The voice ElevenLabs uses for this resident while the account speaks with ElevenLabs, which is much slower to start
      than Phonon on the device. The resident can choose its own voice too; the most recent choice stands, and you can
      change it back here.
    </p>

    {#if loading}
      <p class="text-sm text-muted-foreground">Loading voices…</p>
    {:else if unavailable}
      <p class="text-sm text-muted-foreground">The voice list can't be read just now. Try again shortly.</p>
    {:else}
      <div
        id="agent-voice"
        role="radiogroup"
        aria-labelledby="agent-voice-label"
        class="max-w-xl max-h-80 overflow-y-auto overscroll-contain rounded-md border border-input divide-y divide-border">
        {#snippet row(id, name, detail, colour, icon)}
          {@const isSelected = (selected || '') === id}
          <div
            class="flex items-center gap-3 px-3 py-2 {isSelected ? 'bg-accent' : 'hover:bg-muted/50'}"
            data-testid="voice-option">
            <!-- Native radios sharing one name: the browser gives arrow-key selection
                 and a single tab stop for the group, as the old select did. -->
            <label
              class="flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded-sm has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring">
              <input
                type="radio"
                name="agent-voice"
                class="sr-only"
                value={id}
                checked={isSelected}
                onchange={() => choose(id)} />
              <span
                class="flex size-9 shrink-0 items-center justify-center rounded-full text-sm font-semibold text-white"
                style="background-color: {colour}"
                aria-hidden="true">
                {#if icon}{@render icon()}{:else}{name.slice(0, 1).toUpperCase()}{/if}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-medium">{name}</span>
                {#if detail}<span class="block truncate text-xs text-muted-foreground">{detail}</span>{/if}
              </span>
              {#if isSelected}<Check size={18} weight="bold" class="shrink-0 text-primary" />{/if}
            </label>
            {#if id && voices.some((v) => v.voice_id === id)}
              <Button
                type="button"
                variant="ghost"
                size="sm"
                class="shrink-0"
                aria-label="Preview {name}"
                disabled={previewLoading && previewingId === id}
                onclick={() => preview(id)}>
                <Play size={16} weight="fill" />
              </Button>
            {/if}
          </div>
        {/snippet}
        {#snippet mute()}<SpeakerSlash size={18} weight="bold" />{/snippet}

        {@render row('', 'No voice', 'Not read aloud while the account is on ElevenLabs', 'hsl(0 0% 60%)', mute)}
        {#if current && !currentIsStandard}
          {@render row(current, 'Current voice', 'Not a standard voice', 'hsl(0 0% 40%)', null)}
        {/if}
        {#each voices as v (v.voice_id)}
          {@render row(v.voice_id, v.name, describe(v), `hsl(${hue(v.voice_id)} 60% 45%)`, null)}
        {/each}
      </div>

      <div class="flex flex-wrap items-center gap-2 max-w-xl">
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={!chosen || previewLoading}
          onclick={() => preview()}>
          {previewLoading ? 'Rendering…' : 'Preview'}
        </Button>
        <Button type="button" size="sm" disabled={!changed || busy} onclick={save}>
          {busy ? 'Saving…' : selected ? 'Use this voice' : 'Remove voice'}
        </Button>
      </div>

      {#if chosen?.description}
        <p class="text-xs text-muted-foreground max-w-xl">{chosen.description}</p>
      {/if}
      {#if current && !currentIsStandard}
        <p class="text-xs text-muted-foreground max-w-xl">
          This resident has a voice from before the standard list. It's kept until someone chooses another.
        </p>
      {/if}
      {#if previewSrc}
        {#key previewAttempt}
          <audio
            class="w-full max-w-xl"
            data-testid="voice-preview-audio"
            controls
            autoplay
            src={previewSrc}
            oncanplay={() => (previewLoading = false)}
            onerror={() => {
              previewLoading = false;
              previewError = 'The preview couldn’t be rendered just now.';
            }}></audio>
        {/key}
      {/if}
      {#if previewError}
        <p class="text-sm text-destructive">{previewError}</p>
      {/if}
    {/if}

    {#if error}
      <p class="text-sm text-destructive">{error}</p>
    {/if}
  </div>
{/if}
