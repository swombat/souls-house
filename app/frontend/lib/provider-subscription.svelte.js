import { displayUsageWindows } from '$lib/subscription-usage.js';
import { onDestroy } from 'svelte';
import {
  accountAgentProviderSubscriptionPath,
  accountAgentProviderSubscriptionUsagePath,
  cancelAccountAgentProviderSubscriptionPath,
} from '@/routes';

export function createProviderSubscription(context) {
  let agent = $state({ ...context().subscriptionAgent });
  let connectOpen = $state(false);
  let ceremony = $state(null);
  let actionError = $state(null);
  let startingConnection = $state(false);
  let secondsRemaining = $state(0);
  let pollTimer = null;
  let generation = 0;
  let checking = false;
  const lifetime = new AbortController();
  onDestroy(() => {
    generation++;
    stopPolling();
    lifetime.abort();
  });
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
      ? cancelAccountAgentProviderSubscriptionPath(context().account.id, agent.id)
      : accountAgentProviderSubscriptionPath(context().account.id, agent.id);
  }

  function usagePath() {
    return accountAgentProviderSubscriptionUsagePath(context().account.id, agent.id);
  }

  async function jsonRequest(url, options = {}) {
    const response = await fetch(url, {
      signal: lifetime.signal,
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
    const version = ++generation;
    ceremony = null;
    browserCode = '';
    actionError = null;
    connectOpen = true;
    startingConnection = true;
    stopPolling();
    try {
      const result = await jsonRequest(subscriptionPath(), {
        method: 'POST',
        body: JSON.stringify({ provider: agent.provider }),
      });
      if (version !== generation) return;
      ceremony = result;
      startPolling();
    } catch (error) {
      if (version === generation) actionError = error.message;
    } finally {
      if (version === generation) startingConnection = false;
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
    if (checking || !connectOpen) return;
    checking = true;
    const version = generation;
    try {
      const status = await jsonRequest(`${subscriptionPath()}?provider=${encodeURIComponent(agent.provider)}`);
      if (version !== generation) return;
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
      if (version === generation) {
        stopPolling();
        actionError = error.message;
      }
    } finally {
      checking = false;
    }
  }

  async function cancelConnection() {
    generation++;
    stopPolling();
    connectOpen = false;
    if (startingConnection || ['starting', 'awaiting_code', 'pending', 'finalizing'].includes(ceremony?.status)) {
      try {
        await jsonRequest(subscriptionPath(true), {
          method: 'POST',
          body: JSON.stringify({ provider: agent.provider }),
        });
      } catch {
        // Closing the modal should not be blocked by a best-effort cancellation.
      }
    }
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
    const version = generation;
    actionError = null;
    submittingCode = true;
    try {
      const result = await jsonRequest(`${subscriptionPath()}/code`, {
        method: 'POST',
        body: JSON.stringify({ provider: agent.provider, code: browserCode }),
      });
      if (version !== generation) return;
      ceremony = result;
      browserCode = '';
      startPolling();
    } catch (error) {
      if (version === generation) actionError = error.message;
    } finally {
      submittingCode = false;
    }
  }

  return {
    get agent() {
      return agent;
    },
    get connectOpen() {
      return connectOpen;
    },
    get ceremony() {
      return ceremony;
    },
    get actionError() {
      return actionError;
    },
    get startingConnection() {
      return startingConnection;
    },
    get secondsRemaining() {
      return secondsRemaining;
    },
    get capabilityChecked() {
      return capabilityChecked;
    },
    get subscriptionSupported() {
      return subscriptionSupported;
    },
    get browserCode() {
      return browserCode;
    },
    get submittingCode() {
      return submittingCode;
    },
    get usage() {
      return usage;
    },
    get usageLoading() {
      return usageLoading;
    },
    get usageError() {
      return usageError;
    },
    get displayWindows() {
      return displayWindows;
    },
    get isAnthropic() {
      return isAnthropic;
    },
    get isGemini() {
      return isGemini;
    },
    get subscriptionModeLabel() {
      return subscriptionModeLabel;
    },
    get connectLabel() {
      return connectLabel;
    },
    set browserCode(value) {
      browserCode = value;
    },
    setAuthMode,
    loadUsage,
    beginConnection,
    cancelConnection,
    disconnectSubscription,
    copyCode,
    submitBrowserCode,
  };
}
