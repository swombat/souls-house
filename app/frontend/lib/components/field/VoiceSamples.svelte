<script>
  // A voice's fingerprint samples as a compact review list: play, accept,
  // reject. Each sample is the exact montage that was embedded (several source
  // spans joined), so Accept stays off until it has been played to the end.
  // Namings with no usable sample are a count, listed only on request.
  import { untrack } from 'svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import VoiceSampleRow from './VoiceSampleRow.svelte';
  import OtherNamings from './OtherNamings.svelte';
  import { STATES } from './voice-sample-format.js';

  let { base, name, version = '', onChanged = () => {} } = $props();

  let result = $state(null);
  let loading = $state(false);
  let busy = $state(null);
  let error = $state('');
  let heard = $state({});
  let loadedFor = $state(null);

  let audio = $state(null);
  // What the player actually loaded: the row and the exact digest. A row can
  // be replaced by a refresh while it plays; completion counts only for the
  // digest that was heard (Mira's review of #488).
  let playing = $state(null);
  const playingId = $derived(playing?.id ?? null);
  let page = $state(1);
  let paused = $state(true);
  let progress = $state({});

  const headers = () => ({
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
  });

  async function load(nextPage = page) {
    const url = base;
    loading = true;
    error = '';
    try {
      const response = await fetch(`${url}/samples?page=${nextPage}`, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error('Samples could not be loaded. Please try again.');
      const body = await response.json();
      if (url !== base) return;
      result = body;
      page = body.page || 1;
      // The playing row changed under the player (rebuilt, or gone): stop,
      // and forget its progress, so nothing heard before carries over.
      const row = playing && body.samples.find((sample) => sample.id === playing.id);
      if (playing && (!row || row.digest !== playing.digest || row.audio_url !== playing.url)) {
        const { id } = playing;
        stop();
        const { [id]: _dropped, ...rest } = progress;
        progress = rest;
      }
    } catch (failure) {
      if (url === base) error = failure.message;
    } finally {
      if (url === base) loading = false;
    }
  }

  // A different voice, or a roster change that touched this one: start again.
  $effect(() => {
    const key = `${base}|${version}`;
    untrack(() => {
      if (key === loadedFor) return;
      const sameVoice = loadedFor?.split('|')[0] === base;
      loadedFor = key;
      if (!sameVoice) {
        result = null;
        heard = {};
        progress = {};
        page = 1;
        stop();
      }
      load();
    });
  });

  // Rebuilds run in the background; check again while any is pending.
  $effect(() => {
    if (!result?.samples?.some((sample) => sample.state === 'preparing')) return;
    const timer = setTimeout(() => untrack(load), 4000);
    return () => clearTimeout(timer);
  });

  function stop() {
    if (playing) audio?.pause();
    playing = null;
    paused = true;
  }

  function toggle(sample) {
    if (!audio || !sample.audio_url) return;
    if (playing?.id === sample.id && playing.digest === sample.digest && playing.url === sample.audio_url) {
      if (audio.paused) audio.play();
      else audio.pause();
      return;
    }
    playing = { id: sample.id, digest: sample.digest, url: sample.audio_url };
    audio.src = sample.audio_url;
    audio.currentTime = 0;
    audio.play().catch(() => {
      error = 'This audio could not be played. Check the source recording, then try again.';
    });
  }

  function tick() {
    if (!playingId || !audio?.duration) return;
    progress = { ...progress, [playingId]: audio.currentTime / audio.duration };
  }

  function ended() {
    if (playing) {
      heard = { ...heard, [playing.id]: playing.digest };
      progress = { ...progress, [playing.id]: 1 };
    }
    paused = true;
  }

  async function send(sample, path, method, body) {
    busy = sample?.id ?? 'all';
    error = '';
    try {
      const response = await fetch(path, { method, headers: headers(), body: body && JSON.stringify(body) });
      if (!response.ok) {
        const reply = await response.json().catch(() => ({}));
        throw new Error(reply.error || 'That change could not be saved. Refresh and try again.');
      }
      await load();
      onChanged();
    } catch (failure) {
      error = failure.message;
    } finally {
      busy = null;
    }
  }

  const review = (sample, included) =>
    send(sample, `${base}/samples/${sample.id}`, 'PATCH', { included, digest: sample.digest });
  const prepareAll = () => send(null, `${base}/samples/prepare`, 'POST');

  const heardIt = (sample) => heard[sample.id] === sample.digest;
  // Accepting says "I heard all of this and it is only them". A sample
  // confirmed earlier and later removed can come back without replaying.
  const canAccept = (sample) =>
    sample.source_current &&
    (sample.state === 'review' || sample.state === 'removed') &&
    (heardIt(sample) || (sample.state === 'removed' && sample.confirmed));

  const counts = $derived(result?.state_counts || {});
</script>

<!-- One shared player: only one sample sounds at a time. -->
<audio
  bind:this={audio}
  preload="none"
  class="hidden"
  data-testid="sample-audio"
  onplay={() => (paused = false)}
  onpause={() => (paused = true)}
  ontimeupdate={tick}
  onended={ended}
  onerror={() => {
    if (playingId) error = 'This audio could not be played. Check the source recording, then try again.';
  }}></audio>

<section class="space-y-3" data-testid="voice-samples">
  {#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
  {#if !result && loading}<p class="text-sm text-muted-foreground">Loading samples…</p>{/if}

  {#if result}
    <div class="flex flex-wrap items-center justify-between gap-2">
      <div class="text-sm">
        <p data-testid="voice-print-state">{result.print}</p>
        {#if result.learning !== 'Learning enabled'}<p class="text-muted-foreground">{result.learning}</p>{/if}
      </div>
      {#if result.preparable > 0}
        <Button size="sm" disabled={busy != null} onclick={prepareAll} data-testid="voice-prepare">
          Prepare {result.preparable}
          {result.preparable === 1 ? 'sample' : 'samples'} for listening
        </Button>
      {/if}
    </div>

    {#if result.samples.length === 0}
      <p class="text-sm text-muted-foreground">No fingerprint samples yet.</p>
    {:else}
      <p class="text-xs text-muted-foreground">
        {result.total}
        {result.total === 1 ? 'sample' : 'samples'}
        {#each Object.keys(STATES) as state (state)}
          {#if counts[state]}<span> · {counts[state]} {STATES[state].label.toLowerCase()}</span>{/if}
        {/each}. Accept after playing a sample to the end, if it is only {name} throughout. Wrong person or mixed voices:
        reject it, then correct the speaker in the recording.
      </p>
      <ul class="divide-y rounded-md border" data-testid="voice-sample-list">
        {#each result.samples as sample (sample.id)}
          <VoiceSampleRow
            {sample}
            {name}
            playing={playingId === sample.id && playing.digest === sample.digest && !paused}
            progress={progress[sample.id] ?? null}
            busy={busy != null}
            acceptable={canAccept(sample)}
            onToggle={() => toggle(sample)}
            onReview={(included) => review(sample, included)} />
        {/each}
      </ul>
      {#if result.pages > 1}
        <div class="flex items-center gap-2 text-xs" data-testid="voice-sample-pages">
          <Button size="sm" variant="ghost" disabled={loading || page <= 1} onclick={() => load(page - 1)}
            >Previous</Button>
          <span>Page {page} of {result.pages}</span>
          <Button size="sm" variant="ghost" disabled={loading || page >= result.pages} onclick={() => load(page + 1)}
            >Next</Button>
        </div>
      {/if}
    {/if}

    {#if result.other_namings > 0}
      {#key base}<OtherNamings {base} count={result.other_namings} />{/key}
    {/if}
  {/if}
</section>
