<script>
  // "Sounds like" (spec §9, Identifying). A recognition is never a name: it
  // sits beside the speaker, dashed, until a person confirms or dismisses it.
  // It is never credited to a resident, and the number is shown as a match
  // score, not as a promise.
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { recognition, url } = $props();

  let busy = $state(false);
  let error = $state('');

  const score = $derived(recognition.confidence != null ? Math.round(recognition.confidence) : null);
  // A voice that hasn't passed its check against other recordings yet only
  // hints: "maybe Anna?", said as a hint. Confirming it teaches it the same way.
  const checked = $derived(recognition.checked !== false);

  function send(speaker) {
    busy = true;
    error = '';
    router.patch(
      url,
      { speaker },
      {
        preserveScroll: true,
        preserveState: true,
        onError: (errors) => (error = errors.name || 'That could not be saved. Please try again.'),
        onFinish: () => (busy = false),
      }
    );
  }
</script>

<div
  class="rounded-md border border-dashed px-2 py-1.5 text-sm space-y-1 {checked ? '' : 'opacity-80'}"
  data-testid="speaker-recognition"
  data-checked={checked}>
  <p>
    {#if checked}
      <span class="font-medium">{recognition.name}?</span>
      <span class="text-muted-foreground">sounds like the {recognition.name} this Field remembers</span>
    {:else}
      <span class="font-medium">Maybe {recognition.name}?</span>
      <span class="text-muted-foreground"
        >sounds a bit like {recognition.name}. This voice hasn't been checked against other recordings yet, so it's only
        a hint.</span>
    {/if}
    {#if score != null}
      <span class="text-xs text-muted-foreground" title="How closely the voices match, out of 100">({score})</span>
    {/if}
  </p>
  <div class="flex gap-1">
    <Button
      size="sm"
      variant="outline"
      disabled={busy}
      onclick={() => send({ confirm_recognition: true, recognition: recognition.token })}>
      That's {recognition.name}
    </Button>
    <Button
      size="sm"
      variant="ghost"
      disabled={busy}
      onclick={() => send({ dismiss_recognition: true, recognition: recognition.token })}
      aria-label="Dismiss this suggestion">Not them</Button>
  </div>
  {#if error}<p class="text-xs text-destructive" role="alert">{error}</p>{/if}
</div>
