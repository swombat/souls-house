<script>
  import { ArrowLeft, CheckCircle, TelegramLogo } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import TelegramSettingsGroups from './telegram-settings-groups.svelte';
  import { siteName } from '$lib/branding';
  import { router } from '@inertiajs/svelte';
  import { onDestroy } from 'svelte';
  let {
    form,
    agent,
    accountId,
    telegramConfiguration = null,
    telegramSubscriberCount,
    telegramGroups = [],
    canManageTelegramGroups = false,
    sendingTestNotification,
    registeringWebhook,
    onsendTestNotification,
    onregisterWebhook,
    showIntegrationList,
  } = $props();
  let visibleLink = $state(null);
  let revealing = $state(false);
  let revealGeneration = 0;
  const configured = $derived(telegramConfiguration ? telegramConfiguration.configured : agent.telegram_configured);
  const username = $derived(telegramConfiguration ? telegramConfiguration.username : agent.telegram_bot_username);
  const configurationKey = $derived(JSON.stringify([accountId, agent.id, configured, username]));
  $effect(() => {
    configurationKey;
    revealGeneration++;
    visibleLink = null;
    revealing = false;
  });
  onDestroy(() => {
    revealGeneration++;
  });

  function revealLink() {
    const generation = revealGeneration;
    revealing = true;
    router.reload({
      only: ['telegram_deep_link'],
      preserveState: true,
      preserveScroll: true,
      preserveUrl: true,
      onSuccess: (page) => {
        if (generation === revealGeneration) visibleLink = page.props.telegram_deep_link;
      },
      onFinish: () => {
        if (generation === revealGeneration) revealing = false;
      },
    });
  }
</script>

<div class="space-y-6">
  <button
    type="button"
    class="inline-flex items-center gap-2 text-sm text-muted-foreground transition-colors hover:text-foreground"
    onclick={showIntegrationList}>
    <ArrowLeft size={16} />
    All integrations
  </button>

  <div class="flex items-start gap-4">
    <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-sky-500 text-white">
      <TelegramLogo size={26} weight="fill" />
    </div>
    <div>
      <h2 class="text-xl font-semibold">Telegram</h2>
      <p class="text-sm text-muted-foreground">
        Let people connect with {agent.name} through a Telegram bot for direct messaging.
      </p>
    </div>
  </div>

  {#if !configured}
    <div class="rounded-lg border bg-muted/20 p-5">
      <h3 class="font-semibold">Create a Telegram bot</h3>
      <ol class="mt-4 space-y-4 text-sm">
        <li class="flex gap-3">
          <span
            class="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground"
            >1</span>
          <div>
            Open
            <a
              href="https://t.me/botfather"
              target="_blank"
              rel="noopener noreferrer"
              class="font-medium text-primary underline underline-offset-4">@BotFather in Telegram</a>
            and start a chat.
          </div>
        </li>
        <li class="flex gap-3">
          <span
            class="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground"
            >2</span>
          <div>
            Send <code class="rounded bg-muted px-1.5 py-0.5 text-xs">/newbot</code>, then choose the bot's display name
            and a unique username ending in <code class="rounded bg-muted px-1.5 py-0.5 text-xs">bot</code>.
          </div>
        </li>
        <li class="flex gap-3">
          <span
            class="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground"
            >3</span>
          <div>
            BotFather will reply with an API token. Keep it private: anyone with this token can control the bot.
          </div>
        </li>
        <li class="flex gap-3">
          <span
            class="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground"
            >4</span>
          <div>Paste the username and token below, then save the Telegram settings.</div>
        </li>
      </ol>
    </div>
  {:else}
    <div class="flex items-center gap-2 rounded-lg border border-emerald-500/30 bg-emerald-500/10 p-3 text-sm">
      <CheckCircle class="text-emerald-600" size={20} weight="fill" />
      Telegram is connected as <span class="font-medium">@{username}</span>
    </div>
  {/if}

  <div class="space-y-5 rounded-lg border p-5">
    <div class="space-y-2">
      <Label for="telegram_bot_username">Bot username</Label>
      <Input
        id="telegram_bot_username"
        type="text"
        bind:value={$form.agent.telegram_bot_username}
        placeholder="e.g. my_agent_bot"
        required={!configured} />
      <p class="text-xs text-muted-foreground">Enter the username without the leading @.</p>
    </div>

    <div class="space-y-2">
      <Label for="telegram_bot_token">Bot token</Label>
      <Input
        id="telegram_bot_token"
        type="password"
        bind:value={$form.agent.telegram_bot_token}
        placeholder={configured ? 'Leave blank to keep the current token' : 'Paste the token from BotFather'}
        required={!configured} />
      <p class="text-xs text-muted-foreground">
        {configured
          ? 'Leave this blank unless you want to replace the current token.'
          : 'The token is encrypted when stored and is never shown again.'}
      </p>
    </div>
  </div>

  {#if configured}
    <div class="rounded-lg bg-muted/50 p-4 space-y-2">
      <p class="text-sm font-medium">Your registration link</p>
      <p class="text-xs text-muted-foreground">
        Open this link to connect your own Telegram account for testing. Other users see their own link in the chat UI.
      </p>
      {#if visibleLink}
        <code class="block rounded border bg-background p-2 text-xs break-all">{visibleLink}</code>
      {:else}
        <Button type="button" variant="outline" disabled={revealing} onclick={revealLink}>
          {revealing ? 'Revealing...' : 'Reveal registration link'}
        </Button>
      {/if}
    </div>

    <div class="rounded-lg bg-muted/50 p-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p class="text-sm font-medium">Test messaging</p>
          <p class="text-xs text-muted-foreground">
            {telegramSubscriberCount} subscriber{telegramSubscriberCount === 1 ? '' : 's'} connected
          </p>
        </div>
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={sendingTestNotification || telegramSubscriberCount === 0}
          onclick={onsendTestNotification}>
          {sendingTestNotification ? 'Sending...' : 'Send test message'}
        </Button>
      </div>
    </div>

    <div class="rounded-lg bg-muted/50 p-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p class="text-sm font-medium">Webhook</p>
          <p class="text-xs text-muted-foreground">
            Re-register it if Telegram stops sending updates to {$siteName}.
          </p>
        </div>
        <Button type="button" variant="outline" size="sm" disabled={registeringWebhook} onclick={onregisterWebhook}>
          {registeringWebhook ? 'Registering...' : 'Re-register webhook'}
        </Button>
      </div>
    </div>

    <TelegramSettingsGroups
      {agent}
      {username}
      configuration={telegramConfiguration}
      groups={telegramGroups}
      canManage={canManageTelegramGroups} />
  {/if}

  <div class="flex justify-end gap-3">
    <Button type="button" variant="outline" onclick={showIntegrationList}>Cancel</Button>
    <Button type="submit" disabled={$form.processing}>
      {$form.processing ? 'Saving...' : 'Save Telegram settings'}
    </Button>
  </div>
</div>
