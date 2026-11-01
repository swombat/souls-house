<script>
  import { onMount } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Label } from '$lib/components/shadcn/label';

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

  function preview() {
    if (!chosen) return;
    previewError = null;
    previewLoading = true;
    previewSrc = voice.preview_path_template.replace('VOICE_ID', encodeURIComponent(chosen.voice_id));
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
    <Label for="agent-voice">Voice</Label>
    <p class="text-xs text-muted-foreground">
      What people hear when they press play on this resident's messages. The resident can choose its own voice too; the
      most recent choice stands, and you can change it back here.
    </p>

    {#if loading}
      <p class="text-sm text-muted-foreground">Loading voices…</p>
    {:else if unavailable}
      <p class="text-sm text-muted-foreground">The voice list can't be read just now. Try again shortly.</p>
    {:else}
      <div class="flex flex-wrap items-center gap-2 max-w-xl">
        <select
          id="agent-voice"
          class="h-9 min-w-0 flex-1 rounded-md border border-input bg-background px-3 text-sm"
          bind:value={selected}
          onchange={() => {
            previewSrc = null;
            previewError = null;
            previewLoading = false;
          }}>
          <option value="">No voice</option>
          {#if current && !currentIsStandard}
            <option value={current}>Current voice (not a standard voice)</option>
          {/if}
          {#each voices as v (v.voice_id)}
            <option value={v.voice_id}>{v.name}{describe(v) ? ` · ${describe(v)}` : ''}</option>
          {/each}
        </select>
        <Button type="button" variant="outline" size="sm" disabled={!chosen || previewLoading} onclick={preview}>
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
