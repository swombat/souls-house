import { accountAgentProviderSubscriptionUsagePath } from '@/routes';
import { weeklyRemainingPercent } from '$lib/subscription-usage';

const CACHE_TTL_MS = 60_000;
const usageCache = new Map();

export async function loadAgentWeeklyRemaining(accountId, agent) {
  const subscription = agent?.provider_subscription;
  if (
    !subscription?.available ||
    subscription.auth_mode !== 'oauth_account' ||
    subscription.connection?.status !== 'connected'
  ) {
    return null;
  }

  const key = `${accountId}:${agent.id}`;
  const cached = usageCache.get(key);
  if (cached && cached.expiresAt > Date.now()) return cached.promise;

  const promise = fetch(accountAgentProviderSubscriptionUsagePath(accountId, agent.id), {
    headers: { Accept: 'application/json' },
  })
    .then((response) => {
      if (!response.ok) throw new Error('Usage unavailable');
      return response.json();
    })
    .then((usage) => weeklyRemainingPercent(usage, subscription.provider, agent.model_id))
    .catch(() => null);

  usageCache.set(key, { expiresAt: Date.now() + CACHE_TTL_MS, promise });
  return promise;
}

export function agentNameWithUsage(name, remaining, showUsage) {
  if (remaining === null || remaining === undefined) return name;
  if (!showUsage && remaining >= 25) return name;

  const formatted = remaining.toFixed(remaining % 1 === 0 ? 0 : 1);
  return `${name} (${formatted}% left)`;
}

function compareNames(a, b) {
  return (a?.name || '').localeCompare(b?.name || '', undefined, { sensitivity: 'base' });
}

function hasRemaining(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

// Residents with a subscription (and so a weekly percentage left) come first,
// most available first. Everyone else follows in alphabetical order. Ties on
// percentage fall back to the name so the order stays stable.
export function sortAgentsByAvailability(agents = [], remainingById = {}) {
  return [...agents].sort((a, b) => {
    const ra = remainingById[a.id];
    const rb = remainingById[b.id];
    const ha = hasRemaining(ra);
    const hb = hasRemaining(rb);
    if (ha && hb && ra !== rb) return rb - ra;
    if (ha !== hb) return ha ? -1 : 1;
    return compareNames(a, b);
  });
}

// Loads every resident's weekly remaining percentage (cached per resident) and
// calls onUpdate(agentId, percent | null) as each arrives. Callers merge into
// their existing map, so a refresh keeps the current order until new numbers
// land instead of flickering back to alphabetical. Returns a cancel function.
export function watchAgentsWeeklyRemaining(accountId, agents, onUpdate) {
  let cancelled = false;
  for (const agent of agents) {
    Promise.resolve(loadAgentWeeklyRemaining(accountId, agent)).then((value) => {
      if (!cancelled) onUpdate(agent.id, value);
    });
  }
  return () => {
    cancelled = true;
  };
}
