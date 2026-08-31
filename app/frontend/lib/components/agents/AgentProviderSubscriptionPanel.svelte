<script>
  import Button from '$lib/components/shadcn/button/button.svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Copy } from 'phosphor-svelte';
  import { displayUsageWindows, usageLine } from '$lib/subscription-usage.js';
  import {
    accountAgentProviderSubscriptionPath,
    accountAgentProviderSubscriptionUsagePath,
    cancelAccountAgentProviderSubscriptionPath,
  } from '@/routes';

  let { account, subscriptionAgent, canManage = false, showAgentName = true } = $props();

  let agent = $state({ ...subscriptionAgent });
  let connectOpen = $state(false);
  let ceremony = $state(null);
  let actionError = $state(null);
  let startingConnection = $state(false);
  let secondsRemaining = $state(0);
  let pollTimer = null;
  let capabilityChecked = $state(false);
  let subscriptionSupported = $state(true);
  let browserCode = $state('');
  let submittingCode = $state(false);
  let usage = $state(null);
  let usageLoading = $state(false);
  let usageError = $state(null);
  let displayWindows = $derived(displayUsageWindows(usage, agent.provider, agent.model));
  let isAnthropic = $derived(agent.provider === 'anthropic');
  let isGemini = $derived(agent.provider === 'gemini');
  let subscriptionModeLabel = $derived(
    isAnthropic ? 'Claude Code clamp' : isGemini ? 'Antigravity clamp' : 'Subscription account'
  );
  let connectLabel = $derived(
    isAnthropic ? 'Connect Claude subscription' : isGemini ? 'Connect Google AI subscription' : 'Connect subscription'
  );

  $effect(() => {
    if (!connectOpen || !ceremony?.expires_at) return;

    const updateCountdown = () => {
      secondsRemaining = Math.max(0, Math.ceil((new Date(ceremony.expires_at).getTime() - Date.now()) / 1000));
    };
    updateCountdown();
    const timer = setInterval(updateCountdown, 1000);
    return () => clearInterval(timer);
  });

  $effect(() => () => stopPolling());

  $effect(() => {
    if (!agent.available) return;
    checkCapabilities();
  });

  $effect(() => {
    if (!agent.available || agent.connection?.status !== 'connected') return;
    loadUsage();
  });

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  function subscriptionPath(cancel = false) {
    return cancel
      ? cancelAccountAgentProviderSubscriptionPath(account.id, agent.id)
      : accountAgentProviderSubscriptionPath(account.id, agent.id);
  }

  function usagePath() {
    return accountAgentProviderSubscriptionUsagePath(account.id, agent.id);
  }

  async function jsonRequest(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken(),
        ...(options.headers || {}),
      },
    });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error || 'Provider connection request failed');
    return body;
  }

  async function setAuthMode(authMode) {
    actionError = null;
    try {
      await jsonRequest(subscriptionPath(), {
        method: 'PATCH',
        body: JSON.stringify({ provider: agent.provider, auth_mode: authMode }),
      });
      agent = { ...agent, auth_mode: authMode };
    } catch (error) {
      actionError = error.message;
    }
  }

  async function loadUsage(refresh = false) {
    usageLoading = true;
    usageError = null;
    try {
      usage = await jsonRequest(`${usagePath()}${refresh ? '?refresh=1' : ''}`);
    } catch (error) {
      usageError = error.message;
    } finally {
      usageLoading = false;
    }
  }

  async function checkCapabilities() {
    try {
      const capabilities = await jsonRequest(`${subscriptionPath()}?capabilities=1`);
      subscriptionSupported = capabilities.providers?.[agent.provider]?.oauth_account === true;
    } catch {
      // A temporarily unreachable runtime is already represented by the
      // hosting-health state. Keep the server-side provider fallback rather
      // than making an existing connection disappear.
    } finally {
      capabilityChecked = true;
    }
  }

  async function beginConnection() {
    ceremony = null;
    browserCode = '';
    actionError = null;
    connectOpen = true;
    startingConnection = true;
    stopPolling();
    try {
      ceremony = await jsonRequest(subscriptionPath(), {
        method: 'POST',
        body: JSON.stringify({ provider: agent.provider }),
      });
      startPolling();
    } catch (error) {
      actionError = error.message;
    } finally {
      startingConnection = false;
    }
  }

  function startPolling() {
    stopPolling();
    pollTimer = setInterval(checkConnectionStatus, 2000);
  }

  function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
  }

  async function checkConnectionStatus() {
    try {
      const status = await jsonRequest(`${subscriptionPath()}?provider=${encodeURIComponent(agent.provider)}`);
      if (status.status === 'connected') {
        stopPolling();
        ceremony = status;
        agent = {
          ...agent,
          auth_mode: 'oauth_account',
          connection: {
            status: 'connected',
            email: status.email || null,
            plan: status.plan || null,
            connected_at: new Date().toISOString(),
          },
        };
      } else if (status.status === 'failed' || status.status === 'expired') {
        stopPolling();
        ceremony = status;
      } else {
        ceremony = status;
      }
    } catch (error) {
      stopPolling();
      actionError = error.message;
    }
  }

  async function cancelConnection() {
    stopPolling();
    if (['starting', 'awaiting_code', 'pending', 'finalizing'].includes(ceremony?.status)) {
      try {
        await jsonRequest(subscriptionPath(true), {
          method: 'POST',
          body: JSON.stringify({ provider: agent.provider }),
        });
      } catch {
        // Closing the modal should not be blocked by a best-effort cancellation.
      }
    }
    connectOpen = false;
  }

  async function disconnectSubscription() {
    if (!confirm(`Disconnect ${agent.name} from ${agent.provider_name}?`)) return;

    actionError = null;
    try {
      await jsonRequest(subscriptionPath(), {
        method: 'DELETE',
        body: JSON.stringify({ provider: agent.provider }),
      });
      agent = { ...agent, auth_mode: 'api_key', connection: {} };
    } catch (error) {
      actionError = error.message;
    }
  }

  async function copyCode() {
    if (ceremony?.user_code) await navigator.clipboard.writeText(ceremony.user_code);
  }

  async function submitBrowserCode() {
    actionError = null;
    submittingCode = true;
    try {
      ceremony = await jsonRequest(`${subscriptionPath()}/code`, {
        method: 'POST',
        body: JSON.stringify({ provider: agent.provider, code: browserCode }),
      });
      browserCode = '';
      startPolling();
    } catch (error) {
      actionError = error.message;
    } finally {
      submittingCode = false;
    }
  }
</script>

<div class="rounded-md border bg-muted/20 p-4">
  <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
    <div class="space-y-1">
      {#if showAgentName}
        <div class="font-medium">{agent.name}</div>
      {/if}
      <p class="text-sm text-muted-foreground">
        {agent.provider_name} · {agent.available ? 'Hosted runtime ready' : `Runtime ${agent.runtime}`}
      </p>
      {#if capabilityChecked && !subscriptionSupported}
        <p class="text-xs text-muted-foreground">
          This hosted runtime does not support
          {isAnthropic ? 'Claude Code clamping' : isGemini ? 'Antigravity clamping' : 'subscription account access'}.
        </p>
      {/if}
      {#if subscriptionSupported && agent.connection?.status === 'connected'}
        <p class="text-sm">
          Connected{agent.connection.email ? ` as ${agent.connection.email}` : ''}
          {agent.connection.plan ? ` · ${agent.connection.plan}` : ''}
        </p>
        <p class="text-xs text-muted-foreground">
          {isAnthropic
            ? 'Claude Code clamping is available; select it to draw usage from this Claude plan.'
            : isGemini
              ? 'Experimental Antigravity clamping is available; select it to draw usage from this Google AI plan.'
              : "Resident usage draws on this account's personal plan quota."}
        </p>
        <div class="mt-3 space-y-1.5">
          {#if usageLoading && !usage}
            <p class="text-xs text-muted-foreground">Loading subscription usage…</p>
          {:else if usage?.status === 'unknown' || usageError}
            <div class="flex items-center gap-2">
              <p class="text-xs text-muted-foreground">Usage temporarily unavailable</p>
              <button
                class="text-xs font-medium text-primary hover:underline"
                type="button"
                onclick={() => loadUsage(true)}>
                Refresh
              </button>
            </div>
          {:else if displayWindows.length}
            {#each displayWindows as window (window.id)}
              <div
                class={[
                  'flex items-center justify-between gap-3 rounded-sm px-2 py-1 text-xs',
                  window.blocking && Number(window.remaining_percent) <= 0
                    ? 'bg-amber-500/10 text-amber-800 dark:text-amber-300'
                    : 'bg-muted/50 text-muted-foreground',
                ]}>
                <span>{usageLine(window)}</span>
              </div>
            {/each}
            <button
              class="text-xs font-medium text-primary hover:underline disabled:opacity-50"
              type="button"
              disabled={usageLoading}
              onclick={() => loadUsage(true)}>
              {usageLoading ? 'Refreshing…' : 'Refresh usage'}
            </button>
          {/if}
        </div>
      {:else}
        <p class="text-xs text-muted-foreground">
          {isAnthropic
            ? 'No Claude subscription connected for clamping.'
            : isGemini
              ? 'No Google AI subscription connected through Antigravity.'
              : 'No subscription account connected.'}
        </p>
      {/if}
    </div>

    <div class="flex flex-wrap gap-2">
      <Button
        type="button"
        size="sm"
        variant={agent.auth_mode === 'api_key' ? 'default' : 'outline'}
        disabled={!canManage}
        onclick={() => setAuthMode('api_key')}>
        API key
      </Button>
      {#if agent.connection?.status === 'connected'}
        <Button
          type="button"
          size="sm"
          variant={agent.auth_mode === 'oauth_account' ? 'default' : 'outline'}
          disabled={!canManage}
          onclick={() => setAuthMode('oauth_account')}>
          {subscriptionModeLabel}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={!canManage || !agent.available}
          onclick={beginConnection}>
          Reconnect
        </Button>
        <Button
          type="button"
          size="sm"
          variant="ghost"
          disabled={!canManage || !agent.available}
          onclick={disconnectSubscription}>
          Disconnect
        </Button>
      {:else if subscriptionSupported}
        <Button type="button" size="sm" disabled={!canManage || !agent.available} onclick={beginConnection}>
          {connectLabel}
        </Button>
      {/if}
    </div>
  </div>

  {#if actionError && !connectOpen}
    <div class="mt-3 rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
      {actionError}
    </div>
  {/if}
</div>

<Dialog.Root
  open={connectOpen}
  onOpenChange={(open) => {
    if (!open && connectOpen) cancelConnection();
  }}>
  <Dialog.Content
    onInteractOutside={(event) => {
      event.preventDefault();
      cancelConnection();
    }}>
    <Dialog.Header>
      <Dialog.Title>
        {isAnthropic
          ? 'Connect Claude Code clamping'
          : isGemini
            ? 'Connect Google Antigravity clamping'
            : `Connect ${agent.provider_name} subscription`}
      </Dialog.Title>
      <Dialog.Description>
        {#if isAnthropic}
          Sign Claude Code into the subscription this resident should be clamped to. The connection belongs only to
          {agent.name} and is stored in its private runtime state volume.
        {:else if isGemini}
          Sign the official Antigravity CLI into the Google AI subscription this resident should use. This experimental
          integration is not supported by Google and may put related Gemini developer services at risk. The connection
          belongs only to {agent.name} and is stored in its private runtime state volume.
        {:else}
          This connection belongs only to {agent.name} and is stored in its private runtime state volume.
        {/if}
      </Dialog.Description>
    </Dialog.Header>

    <div class="space-y-4 py-2">
      {#if startingConnection}
        <p class="text-sm text-muted-foreground">Starting provider sign-in…</p>
      {:else if actionError}
        <div class="rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
          {actionError}
        </div>
      {:else if ceremony?.status === 'awaiting_code'}
        <div class="space-y-3">
          <a
            class="font-medium text-primary underline underline-offset-4"
            href={ceremony.verification_url}
            target="_blank"
            rel="noreferrer">
            {isGemini ? 'Open Google sign-in' : 'Open Claude sign-in'}
          </a>
          <p class="text-sm text-muted-foreground">
            {isGemini
              ? 'Complete sign-in in the browser, then paste the authorization code shown by Antigravity below.'
              : 'Complete sign-in in the browser. If the final localhost page does not load, copy its full URL from the address bar and paste it below.'}
          </p>
          <input
            class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            type="text"
            autocomplete="one-time-code"
            bind:value={browserCode}
            placeholder={isGemini
              ? 'Paste the Antigravity authorization code'
              : 'Paste the localhost callback URL or code'} />
          <Button type="button" disabled={!browserCode.trim() || submittingCode} onclick={submitBrowserCode}>
            {submittingCode ? 'Submitting…' : 'Submit code'}
          </Button>
          <p class="text-sm text-muted-foreground">
            {secondsRemaining > 0
              ? `Sign-in expires in ${Math.floor(secondsRemaining / 60)}:${String(secondsRemaining % 60).padStart(2, '0')}.`
              : 'Sign-in expired.'}
          </p>
        </div>
      {:else if ceremony?.status === 'pending'}
        <div class="space-y-3">
          <a
            class="font-medium text-primary underline underline-offset-4"
            href={ceremony.verification_url}
            target="_blank"
            rel="noreferrer">
            Open provider sign-in
          </a>
          <div class="flex items-center gap-2">
            <code class="rounded-md bg-muted px-4 py-2 text-xl font-semibold tracking-widest"
              >{ceremony.user_code}</code>
            <Button type="button" variant="outline" size="icon" aria-label="Copy one-time code" onclick={copyCode}>
              <Copy size={18} />
            </Button>
          </div>
          <p class="text-sm text-muted-foreground">
            {secondsRemaining > 0
              ? `Code expires in ${Math.floor(secondsRemaining / 60)}:${String(secondsRemaining % 60).padStart(2, '0')}.`
              : 'Code expired.'}
          </p>
          <div class="rounded-md border border-amber-400/40 bg-amber-50 p-3 text-sm text-amber-950">
            Device codes are a common phishing target. Never share this code.
          </div>
          <p class="text-sm text-muted-foreground">Waiting for sign-in to finish…</p>
        </div>
      {:else if ceremony?.status === 'finalizing' || ceremony?.status === 'starting'}
        <p class="text-sm text-muted-foreground">Finishing provider sign-in…</p>
      {:else if ceremony?.status === 'connected'}
        <div class="rounded-md border border-emerald-500/30 bg-emerald-500/10 p-4 text-sm">
          {#if isAnthropic}
            Connected successfully{ceremony.email ? ` as ${ceremony.email}` : ''}. Claude Code clamping is now selected,
            and resident usage draws on this Claude plan.
          {:else if isGemini}
            Connected successfully. Antigravity clamping is now selected, and resident usage draws on this Google AI
            plan.
          {:else}
            Connected successfully{ceremony.email ? ` as ${ceremony.email}` : ''}. Resident usage now draws on this
            account's personal plan quota.
          {/if}
        </div>
      {:else if ceremony?.status === 'expired' || ceremony?.status === 'failed'}
        <div class="space-y-3">
          <p class="text-sm text-destructive">{ceremony.message || 'The provider connection was not completed.'}</p>
          <Button type="button" onclick={beginConnection}>Get a new code</Button>
        </div>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={cancelConnection}>
        {ceremony?.status === 'connected' ? 'Done' : 'Cancel'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
