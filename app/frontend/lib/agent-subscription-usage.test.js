import { describe, expect, it } from 'vitest';
import { agentNameWithUsage, sortAgentsByAvailability, loadAgentRemaining } from './agent-subscription-usage';

describe('agent subscription usage labels', () => {
  it('keeps a low OpenAI warning and availability ordering using both supplied windows', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          windows: [
            { id: 'session', remaining_percent: 80 },
            { id: 'weekly', remaining_percent: 20 },
          ],
        }),
      })
    );
    try {
      const low = {
        id: 'openai-low',
        name: 'Mira',
        provider_subscription: {
          available: true,
          auth_mode: 'oauth_account',
          provider: 'openai',
          connection: { status: 'connected' },
        },
      };
      const remaining = await loadAgentRemaining('minimum-allowance', low);
      expect(remaining).toBe(20);
      expect(agentNameWithUsage(low.name, remaining, false)).toBe('Mira (20% left)');
      expect(
        sortAgentsByAvailability([{ id: 'api', name: 'API' }, low, { id: 'high', name: 'High' }], {
          [low.id]: remaining,
          high: 70,
        }).map((agent) => agent.id)
      ).toEqual(['high', low.id, 'api']);
    } finally {
      vi.unstubAllGlobals();
    }
  });
  it('shows usage when the site setting is enabled', () => {
    expect(agentNameWithUsage('Wing', 72, true)).toBe('Wing (72% left)');
  });

  it('hides healthy usage when the site setting is disabled', () => {
    expect(agentNameWithUsage('Wing', 72, false)).toBe('Wing');
  });

  it('always shows usage below 25 percent', () => {
    expect(agentNameWithUsage('Wing', 24.5, false)).toBe('Wing (24.5% left)');
    expect(agentNameWithUsage('Wing', 25, false)).toBe('Wing');
  });
});

describe('sortAgentsByAvailability', () => {
  const agents = [
    { id: 'z', name: 'Zed' },
    { id: 'm', name: 'mira' },
    { id: 'l', name: 'Lume' },
    { id: 'a', name: 'Ash' },
  ];
  const names = (list) => list.map((agent) => agent.name);

  it('sorts alphabetically when nobody has a weekly percentage', () => {
    expect(names(sortAgentsByAvailability(agents, {}))).toEqual(['Ash', 'Lume', 'mira', 'Zed']);
    expect(names(sortAgentsByAvailability(agents, { z: null, m: null }))).toEqual(['Ash', 'Lume', 'mira', 'Zed']);
  });

  it('puts residents with a percentage first, most available first', () => {
    const sorted = sortAgentsByAvailability(agents, { l: 12, z: 80, m: null });
    expect(names(sorted)).toEqual(['Zed', 'Lume', 'Ash', 'mira']);
  });

  it('breaks percentage ties by name', () => {
    expect(names(sortAgentsByAvailability(agents, { z: 50, a: 50 }))).toEqual(['Ash', 'Zed', 'Lume', 'mira']);
  });

  it('does not mutate the input', () => {
    const copy = [...agents];
    sortAgentsByAvailability(agents, { z: 90 });
    expect(agents).toEqual(copy);
  });
});
