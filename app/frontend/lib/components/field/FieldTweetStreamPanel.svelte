<script>
  // The Tweets tab's own panel: follow one public X handle, or see and
  // manage the one already being followed. Shown only when tweet_stream is
  // not null (the house has the feature switched on). Following needs
  // someone to pay: the account's TwitterAPI.io integration, or the house
  // key for accounts granted it (stream.funding); with neither, the panel
  // says so and links to the integration.
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import FieldTweetStreamPanelForm from './FieldTweetStreamPanelForm.svelte';
  import { formatWhenWithTime } from '$lib/field';
  import { streamStateLabel } from '$lib/field-tweets';

  let { accountId, stream } = $props();

  const base = $derived(`/accounts/${accountId}/field/tweet_stream`);

  let working = $state(false);
  let refreshing = $state(false);

  function refreshStatus() {
    if (refreshing) return;
    refreshing = true;
    router.reload({
      only: ['tweet_stream'],
      preserveState: true,
      preserveScroll: true,
      onFinish: () => (refreshing = false),
    });
  }

  function pauseOrResume() {
    if (working) return;
    working = true;
    const action = stream.source.state === 'paused' ? 'resume' : 'pause';
    router.post(`${base}/${action}`, {}, { preserveScroll: true, onFinish: () => (working = false) });
  }

  function stopFollowing() {
    if (!confirm('Tweets already in the Field stay.')) return;
    router.delete(base, { preserveScroll: true });
  }
</script>

<Card.Root class="mb-4" data-testid="field-tweet-stream-panel">
  <Card.Content class="p-4 space-y-4">
    <div class="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
      <p data-testid="tweet-stream-refreshed">
        Status as of refresh{stream.refreshed_at ? `: ${formatWhenWithTime(stream.refreshed_at)}` : ''}. Counts and
        time-based status update when refreshed.
      </p>
      <Button size="sm" variant="ghost" disabled={refreshing} onclick={refreshStatus}>Refresh status</Button>
    </div>
    {#if !stream.source && !stream.funding}
      <div class="space-y-2" data-testid="tweet-stream-needs-integration">
        <p class="font-medium">You need to set up a TwitterAPI.io integration first.</p>
        <p class="text-sm text-muted-foreground">
          Following an X handle reads its new posts through TwitterAPI.io, which charges for every check (about $0.15
          per 1,000 posts, at least $0.00015 a call; an idle handle checked every {stream.poll_minutes} minutes costs about
          $0.43 a month). Add your own TwitterAPI.io key and it pays for this account's tweets.
        </p>
        <Button size="sm" href={stream.integration_url}>Set up TwitterAPI.io</Button>
      </div>
    {:else if stream.source}
      <div class="space-y-1 text-sm">
        <p class="font-medium text-base">
          Following
          <a href={stream.source.url} target="_blank" rel="noopener noreferrer" class="underline"
            >@{stream.source.handle}</a>
        </p>
        <p class="text-muted-foreground" data-testid="field-tweet-stream-state">
          {streamStateLabel(stream.source.state)}{#if stream.source.state_reason}: {stream.source.state_reason}{/if}
        </p>
        <p class="text-muted-foreground">
          Collected through {formatWhenWithTime(stream.source.collected_through)}.
          {#if stream.source.last_success_at}Last success {formatWhenWithTime(stream.source.last_success_at)}.{/if}
          {#if stream.source.next_attempt_at}Next attempt {formatWhenWithTime(stream.source.next_attempt_at)}.{/if}
        </p>
        <p class="text-muted-foreground">
          Imported today: {stream.source.imported_today} of {stream.source.daily_import_cap}.
          {#if stream.source.backlog > 0}{stream.source.backlog} waiting in the backlog.{/if}
        </p>
        {#if stream.source.gap}
          <p class="text-amber-700 dark:text-amber-400" data-testid="field-tweet-stream-gap">
            Posts between {formatWhenWithTime(stream.source.gap.since)} and {stream.source.gap.until
              ? formatWhenWithTime(stream.source.gap.until)
              : 'now'} couldn't be collected.
          </p>
        {/if}
        <p class="text-muted-foreground">
          {#if stream.source.funding === 'own'}
            Paid by this account's TwitterAPI.io integration.
          {:else if stream.source.funding === 'house'}
            Paid by the house.
          {:else}
            Nobody pays for collection right now: <a href={stream.integration_url} class="underline"
              >set up a TwitterAPI.io integration</a> to start it again.
          {/if}
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" disabled={working} onclick={pauseOrResume}>
          {stream.source.state === 'paused' ? 'Resume' : 'Pause'}
        </Button>
        <Button size="sm" variant="ghost" onclick={stopFollowing}>Stop following</Button>
      </div>
    {/if}

    <!-- Keep the follow draft mounted even while funding is unavailable.
         Replacing/deleting a source or switching account deliberately resets it. -->
    {#key JSON.stringify([accountId, stream.source?.id ?? null])}
      <FieldTweetStreamPanelForm {accountId} {stream} />
    {/key}
  </Card.Content>
</Card.Root>
