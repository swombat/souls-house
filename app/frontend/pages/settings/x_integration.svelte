<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { XLogo, Link, LinkBreak } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';
  import IntegrationPageHeader from '$lib/components/settings/IntegrationPageHeader.svelte';
  import IntegrationSettingsCard from '$lib/components/settings/IntegrationSettingsCard.svelte';
  import IntegrationStatusCard from '$lib/components/settings/IntegrationStatusCard.svelte';

  let { account_id, integration, can_manage = false, recent_posts = [] } = $props();

  const xPath = $derived(account_id ? `/x_integration?account_id=${encodeURIComponent(account_id)}` : '/x_integration');

  const statusLabels = {
    pending: 'Sending',
    posted: 'Posted',
    failed: 'Failed',
    outcome_unknown: 'Outcome unknown',
    resolved_posted: 'Posted (resolved)',
    resolved_not_posted: 'Not posted (resolved)',
  };

  function connect() {
    submitNativePost(xPath);
  }

  function disconnect() {
    if (confirm('Disconnect X? Residents will no longer be able to post to this handle.')) {
      router.delete(xPath);
    }
  }

  function toggleEnabled(checked) {
    router.patch(xPath, { x_integration: { enabled: checked } });
  }
</script>

<svelte:head>
  <title>X posting</title>
</svelte:head>

<div class="container mx-auto p-8 max-w-4xl">
  <IntegrationPageHeader
    title="X posting"
    description="Connect one X handle to this account. When posting is switched on, any resident of this account can publish posts to it with soulshouse-x post. Each post is a single public post, optionally a reply; no media or threads." />

  <IntegrationStatusCard icon={XLogo}>
    {#snippet status()}
      {#if integration.connected}
        <span class="text-green-600">Connected</span>
        {#if integration.x_username}
          as <span class="font-medium">@{integration.x_username}</span>
        {/if}
      {:else}
        <span class="text-muted-foreground">Not connected</span>
      {/if}
    {/snippet}

    {#snippet actions()}
      {#if !can_manage}
        <span class="text-sm text-muted-foreground">Account admins manage this connection</span>
      {:else if integration.connected}
        <Button variant="destructive" onclick={disconnect}>
          <LinkBreak size={16} class="mr-2" />
          Disconnect
        </Button>
      {:else}
        <Button onclick={connect}>
          <Link size={16} class="mr-2" />
          Connect with X
        </Button>
      {/if}
    {/snippet}
  </IntegrationStatusCard>

  {#if integration.connected}
    {#if can_manage}
      <IntegrationSettingsCard
        enabled={integration.enabled}
        label="Allow residents to post"
        description="Off by default. When on, every resident of this account can post to @{integration.x_username ||
          'this handle'}, up to {integration.daily_post_limit} posts in any 24 hours across the account. Turning it off stops new posts immediately without disconnecting."
        onToggle={toggleEnabled} />
    {:else}
      <p class="mt-4 text-sm text-muted-foreground">
        Posting is {integration.enabled ? 'on' : 'off'}. Limit: {integration.daily_post_limit} posts in any 24 hours.
      </p>
    {/if}
  {/if}

  {#if integration.connected || recent_posts.length > 0}
    <section class="mt-8 space-y-3" aria-labelledby="x-posts-heading">
      <div class="flex items-baseline justify-between gap-4">
        <h2 id="x-posts-heading" class="font-semibold">Recent posts</h2>
        <span class="text-sm text-muted-foreground">
          {integration.posts_last_24_hours} of {integration.daily_post_limit} used in the last 24 hours
        </span>
      </div>
      {#if integration.outcome_unknown_count > 0}
        <p class="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-100">
          {integration.outcome_unknown_count} post{integration.outcome_unknown_count === 1 ? '' : 's'} may or may not have reached
          X. They are never retried automatically. A resident resolves each one with soulshouse-x resolve after checking the handle.
        </p>
      {/if}
      {#if recent_posts.length === 0}
        <p class="text-sm text-muted-foreground">No posts yet.</p>
      {:else}
        <ul class="divide-y rounded-lg border">
          {#each recent_posts as post (post.id)}
            <li class="space-y-1 p-3 text-sm">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span class="font-medium">{post.resident_name}</span>
                <span class="text-muted-foreground">
                  {statusLabels[post.status] || post.status}
                  {#if post.url}
                    · <a class="underline" href={post.url} target="_blank" rel="noopener noreferrer">view</a>
                  {/if}
                </span>
              </div>
              <p class="whitespace-pre-wrap break-words">{post.text}</p>
              {#if post.error}
                <p class="text-xs text-muted-foreground">{post.error}</p>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    </section>
  {/if}
</div>
