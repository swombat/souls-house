<script>
  import TelegramSettings from '$lib/components/agents/telegram-settings.svelte';
  import {
    CheckCircle,
    TelegramLogo,
    DropboxLogo,
    GoogleLogo,
    GithubLogo,
    ShareNetwork,
    Heartbeat,
  } from 'phosphor-svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let {
    form,
    agent,
    account,
    telegramDeepLink = null,
    telegramSubscriberCount = 0,
    sendingTestNotification = false,
    registeringWebhook = false,
    serviceConnections = [],
    onsendTestNotification,
    onregisterWebhook,
  } = $props();
  let selectedIntegration = $state(null);

  function openTelegram() {
    selectedIntegration = 'telegram';
  }

  function showIntegrationList() {
    selectedIntegration = null;
  }

  function toggleService(connection, enabled) {
    router.patch(connection.access_update_url, { enabled }, { preserveScroll: true });
  }

  function authorityDescription(connection) {
    if (connection.authority_summary) return connection.authority_summary;

    const labels = {
      drive: 'Drive',
      docs: 'Docs',
      sheets: 'Sheets',
      slides: 'Slides',
      calendar: 'Calendar',
      gmail: 'Gmail',
      meet: 'Meet',
    };
    const authority = Object.entries(connection.effective_authority || {})
      .filter(([, level]) => level !== 'none')
      .map(
        ([product, level]) => `${labels[product] || product}: ${level === 'write' ? 'read and write' : 'read only'}`
      );
    if (authority.length > 0) return authority.join('; ');

    const scopes = connection.granted_scopes || [];
    return scopes.length > 0 ? scopes.join(', ') : 'Google did not confirm the granted scopes';
  }
</script>

{#if selectedIntegration === 'telegram'}
  <TelegramSettings
    {form}
    {agent}
    {telegramDeepLink}
    {telegramSubscriberCount}
    {sendingTestNotification}
    {registeringWebhook}
    {onsendTestNotification}
    {onregisterWebhook}
    {showIntegrationList} />
{:else}
  <div class="space-y-6">
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <h2 class="text-xl font-semibold">Integrations</h2>
        <p class="text-sm text-muted-foreground">Connect {agent.name} to the services you use.</p>
      </div>
      <Button href={`/accounts/${account.id}/integrations#connect-new`}>Add integration</Button>
    </div>

    <div class="divide-y rounded-lg border">
      {#each serviceConnections as connection}
        <div class="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between">
          <div class="flex items-center gap-4">
            <div
              class={connection.provider === 'dropbox'
                ? 'flex size-11 shrink-0 items-center justify-center rounded-xl bg-blue-600 text-white'
                : connection.provider === 'google_workspace'
                  ? 'flex size-11 shrink-0 items-center justify-center rounded-xl bg-green-600 text-white'
                  : connection.provider === 'github'
                    ? 'flex size-11 shrink-0 items-center justify-center rounded-xl bg-neutral-900 text-white'
                    : connection.provider === 'tailscale'
                      ? 'flex size-11 shrink-0 items-center justify-center rounded-xl bg-slate-700 text-white'
                      : 'flex size-11 shrink-0 items-center justify-center rounded-xl bg-red-500 text-white'}>
              {#if connection.provider === 'dropbox'}
                <DropboxLogo size={24} weight="fill" />
              {:else if connection.provider === 'google_workspace'}
                <GoogleLogo size={24} weight="bold" />
              {:else if connection.provider === 'github'}
                <GithubLogo size={24} weight="fill" />
              {:else if connection.provider === 'tailscale'}
                <ShareNetwork size={24} weight="bold" />
              {:else}
                <Heartbeat size={24} weight="fill" />
              {/if}
            </div>
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="font-semibold">{connection.label}</h3>
                <span class="rounded-full bg-muted px-2 py-0.5 text-xs"
                  >{connection.management_scope === 'personal' ? 'Personal' : 'Account'}</span>
                {#if connection.enabled}
                  <span
                    class="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 px-2 py-0.5 text-xs font-medium text-emerald-700">
                    <CheckCircle size={13} weight="fill" /> Enabled
                  </span>
                {/if}
              </div>
              <p class="text-sm text-muted-foreground">{connection.provider_name} · {connection.identity}</p>
              <p class="mt-1 text-xs text-muted-foreground">
                This toggle provisions the complete credential authority: {authorityDescription(connection)}
              </p>
              {#each connection.authority_warnings || [] as warning}
                <p class="mt-1 text-xs text-amber-700">{warning}</p>
              {/each}
              {#if connection.provisioning_status}
                <p class="mt-1 text-xs text-muted-foreground">Runtime: {connection.provisioning_status}</p>
              {/if}
            </div>
          </div>
          <Button
            type="button"
            variant={connection.enabled ? 'outline' : 'default'}
            disabled={connection.enabled ? !connection.can_manage : !connection.can_provision}
            onclick={() => toggleService(connection, !connection.enabled)}>
            {connection.enabled ? 'Disable' : 'Enable'}
          </Button>
        </div>
      {/each}
      <div class="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between">
        <div class="flex items-center gap-4">
          <div class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-sky-500 text-white">
            <TelegramLogo size={24} weight="fill" />
          </div>
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="font-semibold">Telegram</h3>
              {#if agent.telegram_configured}
                <span
                  class="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 px-2 py-0.5 text-xs font-medium text-emerald-700">
                  <CheckCircle size={13} weight="fill" />
                  Connected
                </span>
              {/if}
            </div>
            <p class="text-sm text-muted-foreground">
              Chat with the resident and receive notifications through a Telegram bot.
            </p>
          </div>
        </div>

        <button
          type="button"
          class={[
            'inline-flex h-9 items-center justify-center rounded-md px-4 py-2 text-sm font-medium transition-colors',
            agent.telegram_configured
              ? 'border border-input bg-background shadow-sm hover:bg-accent hover:text-accent-foreground'
              : 'bg-primary text-primary-foreground shadow hover:bg-primary/90',
          ]}
          onclick={openTelegram}>
          {agent.telegram_configured ? 'Settings' : 'Set up'}
        </button>
      </div>
    </div>
  </div>
{/if}
