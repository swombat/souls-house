<script>
  // One fingerprint sample: play, what it is, its state, accept or reject.
  // On a phone the status and buttons wrap under the title, so it stays readable.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { ArrowSquareOut, Check, CircleNotch, Pause, Play, X } from 'phosphor-svelte';
  import { STATES, date, seconds, spansTitle } from './voice-sample-format.js';

  let {
    sample,
    name,
    playing = false,
    loading = false,
    progress = null,
    busy = false,
    acceptable = false,
    full = false,
    onToggle,
    onReview,
  } = $props();
  const look = $derived(STATES[sample.state] || STATES.not_ready);
</script>

<li class="flex flex-wrap sm:flex-nowrap items-center gap-x-3 gap-y-1 px-3 py-2 min-w-0" data-testid="voice-sample">
  <button
    type="button"
    class="grid size-9 shrink-0 place-items-center rounded-full border transition-colors
      {sample.audio_url ? 'hover:bg-muted' : 'opacity-40 cursor-not-allowed'}"
    disabled={!sample.audio_url}
    aria-label={`${loading ? 'Loading' : playing ? 'Pause' : 'Play'} sample from ${sample.recording_title || 'recording'}`}
    aria-busy={loading}
    data-testid="sample-play"
    onclick={onToggle}>
    {#if sample.state === 'preparing' || loading}
      <CircleNotch class="size-4 animate-spin" />
    {:else if playing}
      <Pause class="size-4" weight="fill" />
    {:else}
      <Play class="size-4" weight="fill" />
    {/if}
  </button>

  <div class="min-w-0 flex-1 basis-[calc(100%-3.75rem)] sm:basis-auto">
    <div class="flex items-center gap-1 min-w-0">
      <span class="truncate text-sm font-medium">{sample.recording_title || 'Untitled recording'}</span>
      {#if sample.source_url}
        <a
          href={sample.source_url}
          class="shrink-0 text-muted-foreground hover:text-foreground"
          aria-label="Open the recording"
          title="Open the recording"><ArrowSquareOut class="size-3.5" /></a>
      {/if}
    </div>
    <p class="text-xs text-muted-foreground truncate" title={spansTitle(sample)}>
      {date(sample.recorded_at)}
      {#if sample.duration_ms}· {seconds(sample.duration_ms)}{/if}
      {#if sample.segments?.length}· {sample.segments.length}
        {sample.segments.length === 1 ? 'span' : 'spans'}{/if}
      · {sample.label}
    </p>
    {#if progress != null}
      <div class="mt-1 h-1 rounded bg-muted overflow-hidden" aria-hidden="true">
        <div class="h-full bg-primary" style={`width: ${Math.round(progress * 100)}%`}></div>
      </div>
    {/if}
    {#if sample.error}
      <p class="text-xs text-destructive">{sample.error}</p>
    {:else if sample.state === 'not_ready' && sample.unavailable}
      <p class="text-xs text-muted-foreground">{sample.unavailable}</p>
    {/if}
  </div>

  <span
    class="ml-12 sm:ml-0 shrink-0 rounded-full px-2 py-0.5 text-xs whitespace-nowrap {look.tone}"
    data-testid="sample-inclusion"
    title={sample.confirmed
      ? `Confirmed by ${sample.confirmed_by || 'a member'} on ${new Date(sample.confirmed_at).toLocaleString()}`
      : undefined}>
    {look.label}{sample.state === 'removed' && sample.confirmed ? ' · was confirmed' : ''}{sample.saving
      ? ' · saving…'
      : ''}
  </span>

  <div class="ml-auto flex shrink-0 gap-1">
    {#if (!full || sample.included) && sample.source_current && (sample.state === 'review' || sample.state === 'removed')}
      <Button
        size="sm"
        variant="outline"
        disabled={busy || !acceptable}
        title={acceptable ? `Accept: only ${name} throughout` : 'Play it to the end first'}
        aria-label="Accept"
        data-testid="sample-accept"
        onclick={() => onReview(true)}>
        <Check class="size-4" /><span class="hidden sm:inline">Accept</span>
      </Button>
    {/if}
    {#if sample.included || sample.state === 'review'}
      <Button
        size="sm"
        variant="ghost"
        disabled={busy}
        title="Reject: remove from the fingerprint"
        aria-label="Reject"
        data-testid="sample-reject"
        onclick={() => onReview(false)}>
        <X class="size-4" /><span class="hidden sm:inline">Reject</span>
      </Button>
    {/if}
  </div>
</li>
