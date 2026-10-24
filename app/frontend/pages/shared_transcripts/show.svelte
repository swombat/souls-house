<script>
  // A transcript someone shared by link (FieldRecordingShare). Readable by
  // anyone holding the link, signed in or not; it shows only the title, when
  // the recording was made, and the transcript, with a button to copy it.
  //
  // The link's token is in the URL fragment (#sht_…), which browsers never
  // send, so it stays out of request logs. The page reads it and asks for the
  // transcript with a POST, where it is a filtered parameter.
  import { onMount } from 'svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Check, Copy } from 'phosphor-svelte';
  import { copyText } from '$lib/clipboard';
  import { formatDuration } from '$lib/field-recordings';
  import { expiryLine, shareTokenFromHash } from '$lib/transcript-share';

  let state = $state('loading'); // loading | ready | unavailable
  let transcript = $state(null);
  let expired = $state(false);

  async function load() {
    const token = shareTokenFromHash(window.location.hash);
    if (!token) {
      state = 'unavailable';
      return;
    }
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
      const response = await fetch('/shared/transcripts', {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken || '', Accept: 'application/json', 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
        credentials: 'same-origin',
      });
      const body = await response.json().catch(() => ({}));
      if (response.ok && body.transcript) {
        transcript = body.transcript;
        state = 'ready';
      } else {
        expired = !!body.expired;
        state = 'unavailable';
      }
    } catch {
      state = 'unavailable';
    }
  }

  onMount(() => {
    load();
    const reload = () => load();
    window.addEventListener('hashchange', reload);
    return () => window.removeEventListener('hashchange', reload);
  });

  const lines = $derived(transcript?.lines ?? []);
  // An untimed (supplied) transcript has no clock column at all.
  const timed = $derived(lines.some((line) => line.clock));
  const meta = $derived(
    transcript
      ? [
          new Date(transcript.recorded_at).toLocaleDateString(undefined, {
            day: 'numeric',
            month: 'long',
            year: 'numeric',
          }),
          transcript.duration_ms != null ? formatDuration(transcript.duration_ms) : null,
        ]
          .filter(Boolean)
          .join(' · ')
      : ''
  );

  let copied = $state(false);
  async function copy() {
    copied = await copyText(transcript.text);
    if (copied) setTimeout(() => (copied = false), 2000);
  }
</script>

<svelte:head>
  <title>{transcript ? `${transcript.title} · Transcript` : 'Shared transcript'}</title>
  <meta name="robots" content="noindex, nofollow" />
  <meta name="referrer" content="no-referrer" />
</svelte:head>

<div class="mx-auto max-w-3xl px-6 py-10 space-y-6">
  {#if state === 'ready'}
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-3xl font-bold break-words" data-testid="shared-transcript-title">{transcript.title}</h1>
        <p class="text-muted-foreground mt-1">{meta}</p>
        <p class="text-xs text-muted-foreground mt-1">Shared transcript · {expiryLine(transcript.expires_at)}</p>
      </div>
      <Button variant="outline" size="sm" class="shrink-0" onclick={copy} data-testid="copy-shared-transcript">
        {#if copied}
          <Check class="size-4" /> Copied
        {:else}
          <Copy class="size-4" /> Copy to clipboard
        {/if}
      </Button>
    </div>

    <Card.Root>
      <Card.Content class="p-6">
        {#if lines.length}
          <ol class="space-y-3" data-testid="shared-transcript-lines">
            {#each lines as line, index (index)}
              <li class={timed ? 'grid grid-cols-[auto_1fr] gap-x-3' : ''}>
                {#if timed}
                  <span class="text-xs text-muted-foreground tabular-nums pt-1 w-14">{line.clock ?? ''}</span>
                {/if}
                <p class="min-w-0 break-words whitespace-pre-wrap">
                  {#if line.speaker}<span class="font-semibold">{line.speaker}:</span>{' '}{/if}{line.text}
                </p>
              </li>
            {/each}
          </ol>
        {:else}
          <p class="text-muted-foreground">No words were heard in this recording.</p>
        {/if}
      </Card.Content>
    </Card.Root>
  {:else if state === 'unavailable'}
    <div class="py-20 text-center space-y-2" data-testid="shared-transcript-unavailable">
      <h1 class="text-2xl font-semibold">{expired ? 'This link has expired' : 'This link isn’t available'}</h1>
      <p class="text-muted-foreground">
        {expired
          ? 'Ask the person who shared it for a new one.'
          : 'It may have been revoked, or the recording deleted. Ask the person who shared it.'}
      </p>
    </div>
  {:else}
    <p class="py-20 text-center text-muted-foreground" data-testid="shared-transcript-loading">
      Opening the transcript…
    </p>
  {/if}
</div>
