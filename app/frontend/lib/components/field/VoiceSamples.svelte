<script>
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { base, name, onChanged = () => {} } = $props();
  let opened = $state(false);
  let loading = $state(false);
  let busy = $state(null);
  let error = $state('');
  let result = $state(null);
  let heard = $state({});

  async function load(page = 1) {
    loading = true;
    error = '';
    try {
      const response = await fetch(`${base}/samples?page=${page}`, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error('Samples could not be loaded. Please try again.');
      result = await response.json();
    } catch (failure) {
      error = failure.message;
    } finally {
      loading = false;
    }
  }

  async function toggle() {
    opened = !opened;
    if (opened && !result) await load();
  }

  async function act(sample, action) {
    if (action === 'include' && !sample.confirmed) {
      if (
        !confirm(`I listened to this entire sample and confirm that it is ${name} throughout, without another speaker.`)
      )
        return;
    }
    busy = sample.id;
    error = '';
    try {
      const response = await fetch(`${base}/samples/${sample.id}${action === 'relearn' ? '/relearn' : ''}`, {
        method: action === 'relearn' ? 'POST' : 'PATCH',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        body: JSON.stringify({ included: action === 'include', digest: sample.digest }),
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        throw new Error(body.error || 'That change could not be saved. Refresh and try again.');
      }
      await load(result.page);
      onChanged();
    } catch (failure) {
      error = failure.message;
    } finally {
      busy = null;
    }
  }

  function time(ms) {
    return `${(ms / 1000).toFixed(1)}s`;
  }
</script>

<div class="space-y-3" data-testid="voice-samples">
  <Button size="sm" variant="outline" onclick={toggle} aria-expanded={opened}>
    {opened ? 'Hide samples' : 'Review samples'}
  </Button>
  {#if opened}
    {#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
    {#if loading}<p class="text-sm text-muted-foreground">Loading samples…</p>{/if}
    {#if result}
      <div class="text-sm space-y-1">
        <p>{result.print}</p>
        <p class="text-muted-foreground">{result.learning}</p>
        <p class="text-xs text-muted-foreground">
          Listen to the entire sample before approving. A sample may join several source spans. Wrong person or mixed
          voices? Remove it here, then correct the speaker or lines in the recording.
        </p>
      </div>
      <Button size="sm" variant="ghost" onclick={() => load(result.page)} disabled={loading}>Refresh status</Button>
      {#if result.samples.length === 0}
        <p class="text-sm text-muted-foreground">No samples or assigned recordings yet.</p>
      {/if}
      {#each result.samples as sample (sample.id)}
        <article class="rounded-md border p-3 space-y-2 min-w-0" data-testid="voice-sample">
          <a href={sample.source_url} class="font-medium underline break-words"
            >{sample.recording_title || 'Untitled recording'}</a>
          <p class="text-xs text-muted-foreground">
            {new Date(sample.recorded_at).toLocaleDateString()} · {sample.label} · attribution: {sample.naming_source ||
              'unknown'}
          </p>
          <p class="text-sm" data-testid="sample-inclusion">
            {sample.included ? 'Included' : 'Not included'}
            {#if sample.included && !sample.contributing}
              · not in the current fingerprint (different profile or no print){/if}
            · {sample.confirmed ? 'Manually confirmed' : 'Not manually confirmed'}
          </p>
          {#if sample.confirmed}
            <p class="text-xs text-muted-foreground">
              Confirmed by {sample.confirmed_by || 'a member'} on {new Date(sample.confirmed_at).toLocaleString()}.
            </p>
          {/if}
          {#if sample.segments?.length}
            <p class="text-xs text-muted-foreground">
              {time(sample.duration_ms)} total · source spans:
              {sample.segments.map(([from, to]) => `${time(from)}–${time(to)}`).join(', ')}
            </p>
          {/if}
          {#if sample.audio_url}
            <audio
              controls
              preload="none"
              class="w-full max-w-full"
              aria-label={`Sample of ${name} from ${sample.recording_title || 'recording'}`}
              src={sample.audio_url}
              onended={() => (heard = { ...heard, [sample.id]: sample.digest })}
              onerror={() => (error = 'This audio could not be played. Refresh status or check the source recording.')}>
            </audio>
          {/if}
          {#if sample.unavailable}<p class="text-sm text-muted-foreground">{sample.unavailable}</p>{/if}
          {#if sample.status === 'pending'}
            <p class="text-sm">Rebuild pending. Refresh status after processing.</p>
          {/if}
          {#if sample.error}<p class="text-sm text-destructive">{sample.error}</p>{/if}
          <div class="flex flex-wrap gap-2">
            {#if sample.source_current && (!sample.included || !sample.confirmed)}
              <Button
                size="sm"
                disabled={busy != null || (!sample.confirmed && heard[sample.id] !== sample.digest)}
                onclick={() => act(sample, 'include')}>
                {sample.confirmed ? 'Include confirmed sample' : 'Approve & include'}
              </Button>
            {/if}
            {#if sample.included}
              <Button size="sm" variant="outline" disabled={busy != null} onclick={() => act(sample, 'exclude')}>
                Remove from fingerprint
              </Button>
            {/if}
            {#if sample.can_relearn}
              <Button
                size="sm"
                variant="ghost"
                disabled={busy != null || sample.status === 'pending'}
                onclick={() => act(sample, 'relearn')}>
                {sample.status === 'error' ? 'Retry rebuild' : 'Rebuild sample'}
              </Button>
            {/if}
          </div>
          {#if sample.source_current && !sample.confirmed && heard[sample.id] !== sample.digest}
            <p class="text-xs text-muted-foreground">Play the entire sample to enable approval.</p>
          {/if}
        </article>
      {/each}
      <div class="flex flex-wrap items-center gap-2 text-sm">
        <Button size="sm" variant="outline" disabled={loading || result.page <= 1} onclick={() => load(result.page - 1)}
          >Previous</Button>
        <span>Page {result.page} of {result.pages} · {result.total} assigned speakers</span>
        <Button
          size="sm"
          variant="outline"
          disabled={loading || result.page >= result.pages}
          onclick={() => load(result.page + 1)}>Next</Button>
      </div>
    {/if}
  {/if}
</div>
