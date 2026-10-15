<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { XLogo, Link, LinkBreak } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';
  import IntegrationPageHeader from '$lib/components/settings/IntegrationPageHeader.svelte';
  import IntegrationSettingsCard from '$lib/components/settings/IntegrationSettingsCard.svelte';
  import IntegrationStatusCard from '$lib/components/settings/IntegrationStatusCard.svelte';

  let { account_id, integration, can_manage = false, recent_posts = [] } = $props();

  const xPath = $derived(account_id ? `/x_integration?account_id=${encodeURIComponent(account_id)}` : '/x_integration');

  const appPath = $derived(
    account_id ? `/x_integration/app?account_id=${encodeURIComponent(account_id)}` : '/x_integration/app'
  );

  let clientId = $state('');
  let clientSecret = $state('');
  let editingApp = $state(false);

  function saveApp(event) {
    event.preventDefault();
    if (integration.connected && !confirm('Saving a different X app disconnects the handle. Continue?')) return;
    router.put(
      appPath,
      { x_app: { client_id: clientId, client_secret: clientSecret } },
      {
        onSuccess: () => {
          clientId = '';
          clientSecret = '';
          editingApp = false;
        },
      }
    );
  }

  function removeApp() {
    if (confirm('Remove this X app? The handle is disconnected and residents can no longer post.')) {
      router.delete(appPath);
    }
  }

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

  <section class="mb-6 rounded-lg border p-6 space-y-3" aria-labelledby="x-app-heading">
    <h2 id="x-app-heading" class="font-semibold">X app</h2>
    {#if integration.app_source === 'own'}
      <p class="text-sm">
        This account posts through its own X app (client id <code class="break-all">{integration.own_client_id}</code>).
        X charges that app's credits for each post.
      </p>
    {:else if integration.app_source === 'house'}
      <p class="text-sm">
        This account posts through the house X app, {integration.house_app_reason === 'granted'
          ? 'which a site admin has granted it'
          : 'because a site admin is a member of it'}. There is no daily limit.
      </p>
    {:else if integration.house_app_allowed}
      <p class="text-sm text-muted-foreground">
        The house X app is not set up yet. Add the account's own app below, or ask whoever runs the house.
      </p>
    {:else}
      <p class="text-sm text-muted-foreground">
        To post, this account needs its own X app: X charges its pay-per-use credits for every post. Create one at
        developer.x.com with OAuth 2.0 (a confidential client), the scopes tweet.read, tweet.write, users.read and
        offline.access, and this callback URL:
      </p>
    {/if}
    {#if integration.app_source !== 'house' || integration.own_app}
      <p class="text-sm text-muted-foreground">
        Callback URL: <code class="break-all">{integration.callback_url}</code>
      </p>
    {/if}

    {#if can_manage}
      {#if integration.own_app && !editingApp}
        <div class="flex gap-2">
          <Button variant="outline" onclick={() => (editingApp = true)}>Use a different app</Button>
          <Button variant="outline" onclick={removeApp}>Remove app</Button>
        </div>
      {:else if editingApp || integration.app_source !== 'house'}
        <form class="space-y-3" onsubmit={saveApp}>
          <div class="space-y-1">
            <Label for="x_client_id">Client ID</Label>
            <Input id="x_client_id" autocomplete="off" bind:value={clientId} required />
          </div>
          <div class="space-y-1">
            <Label for="x_client_secret">Client secret</Label>
            <Input id="x_client_secret" type="password" autocomplete="off" bind:value={clientSecret} required />
          </div>
          <p class="text-xs text-muted-foreground">The secret is stored encrypted and never shown again.</p>
          <div class="flex gap-2">
            <Button type="submit">Save X app</Button>
            {#if editingApp}
              <Button variant="ghost" type="button" onclick={() => (editingApp = false)}>Cancel</Button>
            {/if}
          </div>
        </form>
      {:else}
        <Button variant="outline" onclick={() => (editingApp = true)}>Use the account's own X app instead</Button>
      {/if}
    {/if}
  </section>

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
      {:else if !integration.app_source}
        <span class="text-sm text-muted-foreground">Add an X app first</span>
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
          'this handle'}. Turning it off stops new posts immediately without disconnecting."
        onToggle={toggleEnabled} />
    {:else}
      <p class="mt-4 text-sm text-muted-foreground">
        Posting is {integration.enabled ? 'on' : 'off'}.
      </p>
    {/if}
  {/if}

  {#if integration.connected || recent_posts.length > 0}
    <section class="mt-8 space-y-3" aria-labelledby="x-posts-heading">
      <h2 id="x-posts-heading" class="font-semibold">Recent posts</h2>
      {#if integration.outcome_unknown_count > 0}
        <p
          class="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-100">
          {integration.outcome_unknown_count} post{integration.outcome_unknown_count === 1 ? '' : 's'} may or may not have
          reached X. They are never retried automatically. A resident resolves each one with soulshouse-x resolve after checking
          the handle.
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
