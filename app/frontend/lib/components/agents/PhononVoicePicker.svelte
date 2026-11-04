<script>
  import { untrack } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Label } from '$lib/components/shadcn/label';
  import { Check, Play } from 'phosphor-svelte';
  import { voices, synthesize } from '$lib/phonon-engine';
  import PhononStatus from '$lib/components/chat/PhononStatus.svelte';

  // The resident's Phonon voice (SpeechEngine): one of Gradium's English
  // voices, made on this device. The default engine, so this is the first
  // voice choice; the ElevenLabs one below it is kept separately. Nothing
  // chosen means the catalogue's default (Delia). Saved on its own, like the
  // picture.
  let { voice = null, name = 'this resident' } = $props();

  const groups = [
    { label: 'American English', match: (v) => v.locale === 'en-us' },
    { label: 'British English', match: (v) => v.locale === 'en-gb' },
    { label: 'Characters', match: (v) => v.locale !== 'en-us' && v.locale !== 'en-gb' },
  ];

  const current = $derived(voice?.current_phonon_voice || voice?.default_phonon_voice || null);
  let selected = $state(untrack(() => voice?.current_phonon_voice || voice?.default_phonon_voice || ''));
  let busy = $state(false);
  let error = $state(null);
  let previewing = $state(null);
  let previewUrl = $state(null);
  let previewError = $state(null);

  const changed = $derived(selected !== current);
  const chosen = $derived(voices.find((v) => v.id === selected) ?? null);

  const detail = (v) => [v.gender, v.age].filter(Boolean).join(', ');

  function hue(id) {
    let h = 0;
    for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return h % 360;
  }

  async function preview(id) {
    selected = id;
    previewing = id;
    previewError = null;
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = null;
    try {
      const text = `Hello, I'm ${name}. This is how I'll sound when you play my messages aloud.`;
      const { blob } = await synthesize(text, { voice: id });
      if (previewing === id) previewUrl = URL.createObjectURL(blob);
    } catch (failure) {
      if (previewing === id) previewError = failure?.message || 'The preview couldn’t be made.';
    } finally {
      if (previewing === id) previewing = null;
    }
  }

  function save() {
    busy = true;
    error = null;
    router.patch(
      voice.update_path,
      { phonon_voice: selected || null },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: (page) => {
          const failed = page?.props?.errors?.phonon_voice;
          if (failed) error = failed;
        },
        onError: (errors) => (error = errors.phonon_voice || 'That didn’t work. Please try again.'),
        onFinish: () => (busy = false),
      }
    );
  }
</script>

{#if voice}
  <div class="space-y-2" data-testid="phonon-voice-picker">
    <Label id="phonon-voice-label">Voice</Label>
    <p class="text-xs text-muted-foreground max-w-xl">
      What people hear when this resident's messages are read aloud, on Listen and in voice mode. These voices are made
      on the listener's device by Phonon, in English.
      {#if voice.speech_engine === 'elevenlabs'}
        This account speaks with ElevenLabs, so this voice is used only if it goes back to Phonon.
      {/if}
    </p>

    <div
      role="radiogroup"
      aria-labelledby="phonon-voice-label"
      class="max-w-xl max-h-80 overflow-y-auto overscroll-contain rounded-md border border-input">
      {#each groups as group}
        {@const members = voices.filter(group.match)}
        {#if members.length}
          <p class="sticky top-0 z-10 bg-muted px-3 py-1 text-xs font-medium text-muted-foreground">{group.label}</p>
          {#each members as v (v.id)}
            {@const isSelected = selected === v.id}
            <div
              class="flex items-center gap-3 px-3 py-2 border-t border-border {isSelected
                ? 'bg-accent'
                : 'hover:bg-muted/50'}"
              data-testid="phonon-voice-option">
              <label
                class="flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded-sm has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring">
                <input
                  type="radio"
                  name="phonon-voice"
                  class="sr-only"
                  value={v.id}
                  checked={isSelected}
                  onchange={() => (selected = v.id)} />
                <span
                  class="flex size-9 shrink-0 items-center justify-center rounded-full text-sm font-semibold text-white"
                  style="background-color: hsl({hue(v.id)} 60% 45%)"
                  aria-hidden="true">{v.name.slice(0, 1)}</span>
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-medium"
                    >{v.name}{#if v.id === voice.default_phonon_voice}<span class="text-muted-foreground font-normal">
                        (default)</span
                      >{/if}</span>
                  {#if detail(v)}<span class="block truncate text-xs text-muted-foreground">{detail(v)}</span>{/if}
                </span>
                {#if isSelected}<Check size={18} weight="bold" class="shrink-0 text-primary" />{/if}
              </label>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                class="shrink-0"
                aria-label="Preview {v.name}"
                disabled={previewing === v.id}
                onclick={() => preview(v.id)}>
                <Play size={16} weight="fill" />
              </Button>
            </div>
          {/each}
        {/if}
      {/each}
    </div>

    <div class="flex flex-wrap items-center gap-2 max-w-xl">
      <Button type="button" size="sm" disabled={!changed || busy || !selected} onclick={save}>
        {busy ? 'Saving…' : 'Use this voice'}
      </Button>
      {#if previewing}<span class="text-xs text-muted-foreground">Making the preview on this device…</span>{/if}
    </div>
    <PhononStatus testid="phonon-voice-status" />
    {#if chosen?.description}
      <p class="text-xs text-muted-foreground max-w-xl">{chosen.description}</p>
    {/if}
    {#if previewUrl}
      <audio class="w-full max-w-xl" data-testid="phonon-voice-preview-audio" controls autoplay src={previewUrl}
      ></audio>
    {/if}
    {#if previewError}<p class="text-sm text-destructive">{previewError}</p>{/if}
    {#if error}<p class="text-sm text-destructive">{error}</p>{/if}
  </div>
{/if}
