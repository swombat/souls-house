import { describe, expect, it } from 'vitest';
import { agentNameWithUsage } from './agent-subscription-usage';

describe('agent subscription usage labels', () => {
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
