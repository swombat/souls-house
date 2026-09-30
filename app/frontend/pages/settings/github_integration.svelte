<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { GithubLogo, Link, LinkBreak, ArrowsClockwise } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';
  import IntegrationPageHeader from '$lib/components/settings/IntegrationPageHeader.svelte';
  import IntegrationSettingsCard from '$lib/components/settings/IntegrationSettingsCard.svelte';
  import IntegrationStatusCard from '$lib/components/settings/IntegrationStatusCard.svelte';

  let { integration } = $props();

  let syncing = $state(false);

  function connect() {
    submitNativePost('/github_integration');
  }

  function disconnect() {
    if (confirm('Disconnect GitHub? Commit data will no longer be shared with residents.')) {
      router.delete('/github_integration');
    }
  }

  function toggleEnabled(checked) {
    router.patch('/github_integration', { github_integration: { enabled: checked } });
  }

  function syncNow() {
    syncing = true;
    router.post(
      '/github_integration/sync',
      {},
      {
        onFinish: () => {
          syncing = false;
        },
      }
    );
  }

  function formatSyncTime(isoString) {
    if (!isoString) return 'Never';
    const date = new Date(isoString);
    return date.toLocaleString();
  }
</script>

<svelte:head>
  <title>GitHub Integration</title>
</svelte:head>

<div class="container mx-auto p-8 max-w-4xl">
  <IntegrationPageHeader
    title="GitHub Integration"
    description="Connect your GitHub account to share recent commit activity with residents." />

  <IntegrationStatusCard icon={GithubLogo}>
    {#snippet status()}
      {#if integration.connected}
        <span class="text-green-600">Connected</span>
        {#if integration.github_username}
          as <span class="font-medium">{integration.github_username}</span>
        {/if}
        {#if integration.repository_full_name}
          &middot; Tracking <span class="font-medium">{integration.repository_full_name}</span>
        {/if}
        {#if integration.commits_synced_at}
          &middot; Last synced {formatSyncTime(integration.commits_synced_at)}
        {/if}
      {:else}
        <span class="text-muted-foreground">Not connected</span>
      {/if}
    {/snippet}

    {#snippet actions()}
      {#if integration.connected}
        {#if integration.repository_full_name}
          <Button variant="outline" onclick={() => router.visit('/github_integration/select_repo')}>Change Repo</Button>
          <Button variant="outline" onclick={syncNow} disabled={syncing}>
            <ArrowsClockwise size={16} class={syncing ? 'mr-2 animate-spin' : 'mr-2'} />
            Sync Now
          </Button>
        {:else}
          <Button onclick={() => router.visit('/github_integration/select_repo')}>
            <Link size={16} class="mr-2" />
            Select Repository
          </Button>
        {/if}
        <Button variant="destructive" onclick={disconnect}>
          <LinkBreak size={16} class="mr-2" />
          Disconnect
        </Button>
      {:else}
        <Button onclick={connect}>
          <Link size={16} class="mr-2" />
          Connect GitHub
        </Button>
      {/if}
    {/snippet}
  </IntegrationStatusCard>

  {#if integration.connected && integration.repository_full_name}
    <IntegrationSettingsCard
      enabled={integration.enabled}
      label="Share commit data with residents"
      description="When enabled, your recent commit messages and activity are included in conversations. This helps residents understand what you've been working on and provide more relevant responses."
      onToggle={toggleEnabled} />
  {/if}
</div>
