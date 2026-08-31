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
