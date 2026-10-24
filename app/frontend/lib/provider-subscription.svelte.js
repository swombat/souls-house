import { displayUsageWindows } from '$lib/subscription-usage.js';
import { onDestroy, untrack } from 'svelte';
import {
  accountAgentProviderSubscriptionPath,
  accountAgentProviderSubscriptionUsagePath,
  cancelAccountAgentProviderSubscriptionPath,
} from '@/routes';

export function createProviderSubscription(context) {
  let agent = $state({ ...context().subscriptionAgent });
  let accountId = $state(context().account.id);
  const identity = (account, value) =>
    value?.id && ['anthropic', 'gemini', 'openai', 'xai'].includes(value.provider)
      ? `${account}:${value.id}:${value.provider}`
      : null;
  let currentIdentity = identity(context().account.id, context().subscriptionAgent);
  let seenPresentation;
  let seenAgent;
  let pendingPresentation;
  let mutating = $state(false);
  let connectOpen = $state(false);
  let ceremony = $state(null);
  let actionError = $state(null);
  let startingConnection = $state(false);
  let secondsRemaining = $state(0);
  let pollTimer = null;
  let generation = 0;
  let identityGeneration = 0;
  let checking = false;
  const lifetime = new AbortController();
  onDestroy(() => {
    generation++;
    identityGeneration++;
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
  let usageStale = $state(false);
  let initialCapabilities = true;
  let initialUsage = true;
  const capabilityKey = $derived(JSON.stringify([accountId, agent.id, agent.provider, agent.available]));
  const usageKey = $derived(JSON.stringify([capabilityKey, agent.model, agent.auth_mode, agent.connection]));
  let capabilityRequest = 0;
  let usageRequest = 0;
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
    const next = context();
    // Track delivered snapshots, not local mutations. A later delivery may
    // legitimately restore the same persisted values after an optimistic edit.
    const presentation = JSON.stringify([next.account.id, next.subscriptionAgent ?? null]);
    const busy = connectOpen || mutating;
    untrack(() => {
      if (presentation !== seenPresentation || next.subscriptionAgent !== seenAgent) {
        seenPresentation = presentation;
        seenAgent = next.subscriptionAgent;
        pendingPresentation = { accountId: next.account.id, agent: { ...next.subscriptionAgent } };
      }
      if (!pendingPresentation) return;
      const nextIdentity = identity(pendingPresentation.accountId, pendingPresentation.agent);
      if (nextIdentity !== currentIdentity || !nextIdentity) {
        // An obsolete identity cannot finish a ceremony against a different
        // resident/provider. Close locally; never send an automatic cancellation.
        generation++;
        identityGeneration++;
        stopPolling();
        connectOpen = false;
        ceremony = null;
        browserCode = '';
        secondsRemaining = 0;
        startingConnection = submittingCode = mutating = checking = false;
        actionError = null;
        currentIdentity = nextIdentity;
      } else if (busy) {
        return;
      }
      accountId = pendingPresentation.accountId;
      agent = pendingPresentation.agent;
      pendingPresentation = null;
    });
  });

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
    const key = capabilityKey;
    untrack(() => {
      const request = ++capabilityRequest;
      capabilityChecked = false;
      subscriptionSupported = true;
      // Preserve the pre-live page-load probe, not one probe per live change.
      if (initialCapabilities && agent.available && identity(accountId, agent)) checkCapabilities(key, request);
      initialCapabilities = false;
    });
  });

  $effect(() => {
    const key = usageKey;
    untrack(() => {
      ++usageRequest;
      usage = null;
      usageError = null;
      usageLoading = false;
      usageStale = !initialUsage;
      if (initialUsage && agent.available && agent.connection?.status === 'connected' && identity(accountId, agent))
        loadUsage(false, key);
      initialUsage = false;
    });
  });

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  function subscriptionPath(cancel = false) {
    return cancel
      ? cancelAccountAgentProviderSubscriptionPath(accountId, agent.id)
      : accountAgentProviderSubscriptionPath(accountId, agent.id);
  }

  function usagePath() {
    return accountAgentProviderSubscriptionUsagePath(accountId, agent.id);
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
    if (!currentIdentity || mutating || connectOpen) return;
    const version = generation;
    mutating = true;
    actionError = null;
    try {
      await jsonRequest(subscriptionPath(), {
        method: 'PATCH',
        body: JSON.stringify({ provider: agent.provider, auth_mode: authMode }),
      });
      if (version === generation) updateAgent({ auth_mode: authMode });
    } catch (error) {
      if (version === generation) actionError = error.message;
    } finally {
      if (version === generation) mutating = false;
    }
  }

  // A refresh received before a successful local write must not undo that
  // write when the deferred snapshot is adopted. Other fields still reconcile.
  function updateAgent(changes) {
    agent = { ...agent, ...changes };
    if (pendingPresentation) {
      pendingPresentation.agent = { ...pendingPresentation.agent, ...changes };
    }
  }

  async function loadUsage(refresh = false, key = usageKey) {
    if (!currentIdentity) return;
    const request = ++usageRequest;
    const version = identityGeneration;
    const current = () => version === identityGeneration && key === usageKey && request === usageRequest;
    usageLoading = true;
    usageError = null;
    try {
      const result = await jsonRequest(`${usagePath()}${refresh ? '?refresh=1' : ''}`);
      if (current()) {
        usage = result;
        usageStale = false;
      }
    } catch (error) {
      if (current()) usageError = error.message;
    } finally {
      if (current()) usageLoading = false;
    }
  }

  async function checkCapabilities(key, request) {
    const version = identityGeneration;
    const provider = agent.provider;
    const current = () => version === identityGeneration && key === capabilityKey && request === capabilityRequest;
    try {
      const capabilities = await jsonRequest(`${subscriptionPath()}?capabilities=1`);
      if (current()) subscriptionSupported = capabilities.providers?.[provider]?.oauth_account === true;
    } catch {
      // A temporarily unreachable runtime is already represented by the
      // hosting-health state. Keep the server-side provider fallback rather
      // than making an existing connection disappear.
    } finally {
      if (current()) capabilityChecked = true;
    }
  }

  async function beginConnection() {
    if (!currentIdentity || mutating || startingConnection || submittingCode) return;
    const version = ++generation;
    checking = false;
    ceremony = null;
    browserCode = '';
    secondsRemaining = 0;
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
        updateAgent({
          auth_mode: 'oauth_account',
          connection: {
            status: 'connected',
            email: status.email || null,
            plan: status.plan || null,
            connected_at: new Date().toISOString(),
          },
        });
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
      if (version === generation) checking = false;
    }
  }

  async function cancelConnection() {
    generation++;
    checking = false;
    stopPolling();
    connectOpen = false;
    mutating = true;
    const version = generation;
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
    if (version === generation) {
      startingConnection = false;
      submittingCode = false;
      mutating = false;
    }
  }

  async function disconnectSubscription() {
    if (!currentIdentity || mutating || connectOpen) return;
    if (!confirm(`Disconnect ${agent.name} from ${agent.provider_name}?`)) return;

    const version = generation;
    mutating = true;
    actionError = null;
    try {
      await jsonRequest(subscriptionPath(), {
        method: 'DELETE',
        body: JSON.stringify({ provider: agent.provider }),
      });
      if (version === generation) updateAgent({ auth_mode: 'api_key', connection: {} });
    } catch (error) {
      if (version === generation) actionError = error.message;
    } finally {
      if (version === generation) mutating = false;
    }
  }

  async function copyCode() {
    if (ceremony?.user_code) await navigator.clipboard.writeText(ceremony.user_code);
  }

  async function submitBrowserCode() {
    if (!currentIdentity || !connectOpen || submittingCode || startingConnection) return;
    const version = ++generation;
    checking = false;
    stopPolling();
    const submittedCode = browserCode;
    actionError = null;
    submittingCode = true;
    try {
      const result = await jsonRequest(`${subscriptionPath()}/code`, {
        method: 'POST',
        body: JSON.stringify({ provider: agent.provider, code: submittedCode }),
      });
      if (version !== generation) return;
      ceremony = result;
      if (browserCode === submittedCode) browserCode = '';
      startPolling();
    } catch (error) {
      if (version === generation) actionError = error.message;
    } finally {
      if (version === generation) submittingCode = false;
    }
  }

  return {
    get valid() {
      return Boolean(identity(accountId, agent));
    },
    get mutating() {
      return mutating;
    },
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
    get usageStale() {
      return usageStale;
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
