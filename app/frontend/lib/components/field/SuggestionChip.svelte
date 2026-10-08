<script>
  // "Suggested from what's said" (spec §8). A suggestion is never a name: it
  // sits beside the speaker, dashed, with the line that supports it, until a
  // person confirms or dismisses it. It is never credited to a resident.
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { formatClock, parseNameMatch } from '$lib/field-recordings';

  let { suggestion, url, onSeek } = $props();

  let busy = $state(false);
  let match = $state(null);
  let error = $state('');

  function send(speaker) {
    busy = true;
    error = '';
    router.patch(
      url,
      { speaker },
      {
        preserveScroll: true,
        preserveState: true,
        onSuccess: () => (match = null),
        onError: (errors) => {
          const asked = parseNameMatch(errors.name_match);
          if (asked) match = asked;
          else error = errors.name || 'That could not be saved. Please try again.';
        },
        onFinish: () => (busy = false),
      }
    );
  }
</script>

<div class="rounded-md border border-dashed px-2 py-1.5 text-sm space-y-1" data-testid="speaker-suggestion">
  <p>
    <span class="font-medium">{suggestion.name}?</span>
    <span class="text-muted-foreground">says</span>
    <button
      type="button"
      class="font-sans italic underline decoration-dotted underline-offset-2 hover:text-foreground text-muted-foreground"
      onclick={() => onSeek?.(suggestion.quote_ms)}
      aria-label={`Play from ${formatClock(suggestion.quote_ms)}`}>“{suggestion.quote}”</button>
    <span class="text-xs text-muted-foreground">({formatClock(suggestion.quote_ms)})</span>
  </p>
  <p class="text-xs text-muted-foreground">{suggestion.label}</p>
  {#if match}
    <p class="text-xs">Same {match.name}{match.last_named_in ? ` as in ${match.last_named_in}` : ' as before'}?</p>
    <div class="flex gap-1">
      <Button
        size="sm"
        disabled={busy}
        onclick={() =>
          send({ confirm_suggestion: true, link_existing: true, suggestion_generation: suggestion.generation })}
        >Yes</Button>
      <Button size="sm" variant="ghost" disabled={busy} onclick={() => (match = null)}>No</Button>
    </div>
  {:else}
    <div class="flex gap-1">
      <Button
        size="sm"
        variant="outline"
        disabled={busy}
        onclick={() => send({ confirm_suggestion: true, suggestion_generation: suggestion.generation })}>
        That's {suggestion.name}
      </Button>
      <Button
        size="sm"
        variant="ghost"
        disabled={busy}
        onclick={() => send({ dismiss_suggestion: true, suggestion_generation: suggestion.generation })}
        aria-label="Dismiss this suggestion">Not them</Button>
    </div>
  {/if}
  {#if error}<p class="text-xs text-destructive">{error}</p>{/if}
</div>
