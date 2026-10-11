<script>
  // The Tweets tab's own panel: follow one public X handle, or see and
  // manage the one already being followed. Shown only when tweet_stream is
  // not null (the house has the feature switched on).
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { formatWhenWithTime } from '$lib/field';
  import { streamStateLabel } from '$lib/field-tweets';

  let { accountId, stream } = $props();

  const base = $derived(`/accounts/${accountId}/field/tweet_stream`);

  // Follow form: only shown while there is no source yet.
  let handle = $state('');
  let includeReplies = $state(true);
  let includeQuotes = $state(true);
  let includeReposts = $state(false);
  let apiKey = $state('');
  let ownLimit = $state('5');
  let following = $state(false);

  function follow(event) {
    event.preventDefault();
    const value = handle.trim().replace(/^@/, '');
    if (!value || following) return;
    following = true;
    router.post(
      base,
      {
        field_tweet_source: {
          handle: value,
          include_replies: includeReplies,
          include_quotes: includeQuotes,
          include_reposts: includeReposts,
          api_key: apiKey.trim(),
          own_monthly_usd_limit: ownLimit,
        },
      },
      { preserveScroll: true, onFinish: () => (following = false) }
    );
  }

  // Settings form: only shown once a source exists, prefilled from it.
  let settingsReplies = $state(false);
  let settingsQuotes = $state(false);
  let settingsReposts = $state(false);
  let settingsKey = $state('');
  let settingsRemoveKey = $state(false);
  let settingsLimit = $state('5');
  let savingSettings = $state(false);
  let working = $state(false);

  $effect(() => {
    const source = stream.source;
    if (!source) return;
    settingsReplies = source.include_replies;
    settingsQuotes = source.include_quotes;
    settingsReposts = source.include_reposts;
    settingsLimit = source.own_monthly_usd_limit;
    settingsKey = '';
    settingsRemoveKey = false;
  });

  function saveSettings(event) {
    event.preventDefault();
    if (savingSettings) return;
    savingSettings = true;
    router.patch(
      base,
      {
        field_tweet_source: {
          include_replies: settingsReplies,
          include_quotes: settingsQuotes,
          include_reposts: settingsReposts,
          api_key: settingsKey.trim(),
          remove_api_key: settingsRemoveKey ? 'true' : 'false',
          own_monthly_usd_limit: settingsLimit,
        },
      },
      { preserveScroll: true, onFinish: () => (savingSettings = false) }
    );
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
    {#if !stream.source}
      <form onsubmit={follow} class="space-y-3" data-testid="tweet-stream-follow-form">
        <div class="space-y-1">
          <Label for="tweet-stream-handle">Follow an X handle</Label>
          <Input id="tweet-stream-handle" bind:value={handle} placeholder="jack" maxlength={16} required />
        </div>
        <div class="space-y-1.5">
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={includeReplies} /> Include its replies
          </label>
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={includeQuotes} /> Include its quote-posts
          </label>
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={includeReposts} /> Include its reposts
          </label>
        </div>
        <div class="space-y-1">
          <Label for="tweet-stream-key"
            >Your own TwitterAPI.io key <span class="text-muted-foreground">(optional)</span></Label>
          <Input id="tweet-stream-key" type="password" autocomplete="off" bind:value={apiKey} />
        </div>
        {#if apiKey.trim()}
          <div class="space-y-1">
            <Label for="tweet-stream-limit">Your monthly limit (USD)</Label>
            <Input
              id="tweet-stream-limit"
              type="number"
              min="0"
              max="100"
              step="0.01"
              class="w-28"
              bind:value={ownLimit} />
          </div>
        {/if}
        <p class="text-sm text-muted-foreground">
          Posts from now on are brought in, not its history. Checked every {stream.poll_minutes} minutes, up to {stream.daily_import_cap}
          new tweets a day.
          {#if stream.house_available || apiKey.trim()}
            Paid by the house, up to ${stream.account_monthly_usd_ceiling} a month, unless a key is given above.
          {:else}
            Collection paid by the house isn't available yet, so a key is needed for now.
          {/if}
          Search may miss or delay some posts; this is not a complete archive.
        </p>
        <Button type="submit" size="sm" disabled={!handle.trim() || following}>Follow</Button>
      </form>
    {:else}
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
          {stream.source.funding === 'own' ? 'Paid by your own key.' : 'Paid by the house.'}
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" disabled={working} onclick={pauseOrResume}>
          {stream.source.state === 'paused' ? 'Resume' : 'Pause'}
        </Button>
        <Button size="sm" variant="ghost" onclick={stopFollowing}>Stop following</Button>
      </div>

      <form onsubmit={saveSettings} class="space-y-3 border-t pt-3" data-testid="tweet-stream-settings-form">
        <div class="space-y-1.5">
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={settingsReplies} /> Include its replies
          </label>
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={settingsQuotes} /> Include its quote-posts
          </label>
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={settingsReposts} /> Include its reposts
          </label>
        </div>
        <div class="space-y-1">
          <Label for="tweet-stream-settings-key">
            {stream.source.has_own_key ? 'Replace your key' : 'Your own TwitterAPI.io key'}
            <span class="text-muted-foreground">(leave blank to keep it unchanged)</span>
          </Label>
          <Input id="tweet-stream-settings-key" type="password" autocomplete="off" bind:value={settingsKey} />
        </div>
        {#if stream.source.has_own_key}
          <label class="flex items-center gap-2 text-sm">
            <input type="checkbox" bind:checked={settingsRemoveKey} /> Remove my key
          </label>
        {/if}
        <div class="space-y-1">
          <Label for="tweet-stream-settings-limit">Your monthly limit (USD)</Label>
          <Input
            id="tweet-stream-settings-limit"
            type="number"
            min="0"
            max="100"
            step="0.01"
            class="w-28"
            bind:value={settingsLimit} />
        </div>
        <Button type="submit" size="sm" variant="outline" disabled={savingSettings}>Save settings</Button>
      </form>
    {/if}
  </Card.Content>
</Card.Root>
