<script>
  import { onDestroy } from 'svelte';
  import { cn } from '$lib/utils.js';
  import { HUE_SWATCHES, normaliseHue, applyPersonalTint } from '$lib/theme';

  // value: an integer hue 0-359, or null for the default (untinted) look.
  // saved: the hue currently stored, restored if the form is left without saving.
  // No fallback on the binding: a form may hold the field as undefined (never set), and
  // Svelte rejects binding undefined to a prop with a non-undefined fallback.
  let { value = $bindable(), saved = null } = $props();

  const hue = $derived(normaliseHue(value));

  // Preview the tint on the whole page while choosing.
  $effect(() => {
    applyPersonalTint(document.documentElement, hue);
  });
  onDestroy(() => applyPersonalTint(document.documentElement, saved));

  // Swatch fill: the light-mode panel shade, saturated enough to read as a choice.
  function swatchStyle(swatchHue) {
    return `background-color: oklch(0.9 0.06 ${swatchHue})`;
  }
</script>

<div class="space-y-3" data-testid="theme-hue-picker">
  <div class="flex flex-wrap gap-2" role="radiogroup" aria-label="Colour theme">
    <button
      type="button"
      role="radio"
      aria-checked={hue === null}
      onclick={() => (value = null)}
      class={cn(
        'h-9 rounded-full border px-3 text-sm',
        hue === null ? 'ring-2 ring-ring ring-offset-2 ring-offset-background' : ''
      )}>Default</button>
    {#each HUE_SWATCHES as swatch (swatch.name)}
      <button
        type="button"
        role="radio"
        aria-checked={hue === swatch.hue}
        aria-label={swatch.name}
        title={swatch.name}
        onclick={() => (value = swatch.hue)}
        style={swatchStyle(swatch.hue)}
        class={cn(
          'h-9 w-9 rounded-full border',
          hue === swatch.hue ? 'ring-2 ring-ring ring-offset-2 ring-offset-background' : ''
        )}></button>
    {/each}
  </div>
  <label class="flex items-center gap-3 text-sm text-muted-foreground">
    <span class="shrink-0">Any hue</span>
    <input
      type="range"
      min="0"
      max="359"
      step="1"
      value={hue ?? 0}
      oninput={(event) => (value = Number(event.currentTarget.value))}
      class="theme-hue-slider w-full max-w-sm"
      aria-label="Hue" />
  </label>
</div>

<style>
  .theme-hue-slider {
    appearance: none;
    height: 0.6rem;
    border-radius: 9999px;
    background: linear-gradient(
      to right,
      oklch(0.85 0.08 0),
      oklch(0.85 0.08 60),
      oklch(0.85 0.08 120),
      oklch(0.85 0.08 180),
      oklch(0.85 0.08 240),
      oklch(0.85 0.08 300),
      oklch(0.85 0.08 359)
    );
  }
</style>
