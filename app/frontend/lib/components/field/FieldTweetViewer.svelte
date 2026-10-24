<script>
  // A tweet brought in by a stream: the post itself, what it replies to or
  // quotes, its media and metrics, and a link back to X.
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { ArrowBendUpLeft, ArrowSquareOut, Trash } from 'phosphor-svelte';
  import { formatWhenWithTime } from '$lib/field';
  import { metricEntries, tweetBadge } from '$lib/field-tweets';

  let { tweet, onDelete } = $props();

  const badge = $derived(tweetBadge(tweet.kinds));
  const metrics = $derived(metricEntries(tweet.metrics));
  const media = $derived((tweet.media || []).slice(0, 4));
</script>

<Card.Root data-testid="field-tweet-viewer">
  <Card.Content class="p-6 space-y-4">
    <div>
      <h2 class="text-xl font-semibold break-words">
        {tweet.author_name}
        <span class="text-muted-foreground font-normal">@{tweet.author_handle}</span>
      </h2>
      <p class="text-sm text-muted-foreground mt-1">
        {#if badge}
          <span class="inline-flex items-center rounded-full bg-muted px-2 py-0.5 text-xs mr-1">{badge}</span>
        {/if}
        {formatWhenWithTime(tweet.posted_at)}
      </p>
    </div>

    {#if tweet.in_reply_to_url}
      <p class="text-sm text-muted-foreground">
        <ArrowBendUpLeft class="inline size-3.5 -mt-0.5" />
        Replying to
        <a href={tweet.in_reply_to_url} target="_blank" rel="noopener noreferrer" class="underline">
          @{tweet.in_reply_to_handle || 'this post'}
        </a>
      </p>
    {/if}

    <p class="whitespace-pre-wrap break-words" data-testid="field-tweet-text">{tweet.text}</p>

    {#if tweet.related}
      <div class="rounded-md border p-3 text-sm" data-testid="field-tweet-related">
        <p class="text-muted-foreground">@{tweet.related.author_handle}</p>
        <p class="whitespace-pre-wrap break-words mt-1">{tweet.related.text}</p>
      </div>
    {/if}

    {#if media.length}
      <div class="grid grid-cols-2 gap-2" data-testid="field-tweet-media">
        {#each media as item, index (index)}
          <img
            src={item.url}
            alt={item.alt || ''}
            loading="lazy"
            referrerpolicy="no-referrer"
            class="h-40 w-full rounded-md border object-cover" />
        {/each}
      </div>
    {/if}

    {#if metrics.length}
      <p class="text-sm text-muted-foreground" data-testid="field-tweet-metrics">
        {metrics.map((m) => `${m.value} ${m.label}`).join(' · ')}
        {#if tweet.metrics_at}
          <br />
          <span class="text-xs">as of {formatWhenWithTime(tweet.metrics_at)}</span>
        {/if}
      </p>
    {/if}

    <div class="flex flex-wrap gap-2">
      <Button href={tweet.url} target="_blank" rel="noopener noreferrer" variant="outline" size="sm">
        <ArrowSquareOut class="size-4" /> Open on X
      </Button>
      <Button variant="ghost" size="sm" onclick={onDelete}>
        <Trash class="size-4" /> Delete
      </Button>
    </div>
  </Card.Content>
</Card.Root>
