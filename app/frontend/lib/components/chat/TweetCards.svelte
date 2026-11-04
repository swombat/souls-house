<script>
  // Cards for X posts a message links (JdwnWj). Text is rendered as text,
  // never as HTML; media URLs were checked on the server (twimg hosts only).
  let { tweets = [] } = $props();

  function postedOn(iso) {
    if (!iso) return '';
    const date = new Date(iso);
    return isNaN(date) ? '' : date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }
</script>

{#if tweets.length}
  <div class="my-3 space-y-2" aria-label="Posts on X">
    {#each tweets as tweet (tweet.id)}
      <article class="rounded-lg border border-border bg-background/70 p-3 text-sm" data-tweet-id={tweet.id}>
        <header class="flex flex-wrap items-baseline gap-x-2">
          {#if tweet.author_name}<span class="font-medium">{tweet.author_name}</span>{/if}
          <span class="text-muted-foreground">@{tweet.author_handle}</span>
          {#if tweet.posted_at}<span class="text-xs text-muted-foreground">· {postedOn(tweet.posted_at)}</span>{/if}
        </header>
        {#if tweet.text}<p class="mt-1 whitespace-pre-wrap [overflow-wrap:anywhere]">{tweet.text}</p>{/if}
        {#if tweet.media && tweet.media.length}
          <div class="mt-2 grid grid-cols-2 gap-1">
            {#each tweet.media as item (item.url)}
              <a href={tweet.url} target="_blank" rel="noopener noreferrer">
                <img src={item.url} alt={item.alt || ''} loading="lazy" referrerpolicy="no-referrer" class="max-h-64 w-full rounded object-cover" />
              </a>
            {/each}
          </div>
        {/if}
        {#if tweet.quoted && tweet.quoted.text}
          <blockquote class="mt-2 rounded border border-border p-2 text-muted-foreground">
            {#if tweet.quoted.author_handle}<span class="text-xs">@{tweet.quoted.author_handle}</span>{/if}
            <p class="whitespace-pre-wrap [overflow-wrap:anywhere]">{tweet.quoted.text}</p>
          </blockquote>
        {/if}
        <a href={tweet.url} target="_blank" rel="noopener noreferrer" class="mt-2 inline-block text-xs text-primary hover:underline">View on X</a>
      </article>
    {/each}
  </div>
{/if}
