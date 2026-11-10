import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import HouseAllowance from './house-allowance.svelte';

describe('House allowance', () => {
  it('shows funding, privacy, reset and remaining amount', () => {
    render(HouseAllowance, {
      selectedModel: 'house/deepseek-v4.1-flash',
      allowance: {
        remaining_usd: 7.125,
        resets_at: '2026-10-01',
        configured: true,
      },
    });
    expect(screen.getByText(/\$7.13 remaining/)).toBeTruthy();
    expect(screen.getByText(/Fireworks’ US endpoint/)).toBeTruthy();
    expect(screen.getByText(/One funded resident per user/)).toBeTruthy();
  });
  it('describes a free-hosting allowance as the resident’s own, not a per-user grant', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { source: 'free', limit_usd: 10, remaining_usd: 4.5, resets_at: '2026-11-01', configured: true },
    });
    expect(screen.getByText(/Free hosting · \$10 per month/)).toBeTruthy();
    expect(screen.getByText(/isn't\s+shared with your other residents/)).toBeTruthy();
    expect(screen.queryByText(/One funded resident per user/)).toBeNull();
    expect(screen.queryByText(/One funded model call runs at a time/)).toBeNull();
    expect(screen.getByText(/\$4.50 remaining/)).toBeTruthy();
  });
  it('during the free trial says $10 for the trial, not a month, and until when', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: {
        source: 'plan',
        plan: 'Small',
        rate: 'standard',
        limit_usd: 10,
        remaining_usd: 6.5,
        resets_at: '2026-12-01',
        trial_ends_at: '2026-11-24T12:00:00Z',
        configured: true,
      },
    });
    expect(screen.getByRole('heading', { name: 'Small · $10 for the free trial' })).toBeTruthy();
    expect(screen.getByText(/\$10 in all until 24 Nov 2026,\s+not \$10 a month/)).toBeTruthy();
    expect(screen.getByText('$6.50 remaining · until 24 Nov 2026')).toBeTruthy();
    expect(screen.queryByText(/this month/)).toBeNull();
    expect(screen.queryByText(/resets 2026-12-01/)).toBeNull();
  });
  it('does not label personal models as funded', () => {
    render(HouseAllowance, { selectedModel: 'anthropic/claude-haiku-5.5' });
    expect(screen.queryByLabelText('House inference allowance')).toBeNull();
  });
  it('discloses the Anthropic route for Haiku', () => {
    render(HouseAllowance, { selectedModel: 'house/claude-haiku-5.5' });
    expect(screen.getByText(/pinned to Anthropic’s own API/)).toBeTruthy();
    expect(screen.queryByText(/Fireworks/)).toBeNull();
  });
  it('does not label personal DeepSeek as funded', () => {
    render(HouseAllowance, { selectedModel: 'deepseek/deepseek-v4.1-flash' });
    expect(screen.queryByLabelText('House inference allowance')).toBeNull();
  });
  it('names missing operator configuration instead of asking for personal keys', () => {
    render(HouseAllowance, {
      selectedModel: 'house/deepseek-v4.1-flash',
      allowance: {
        remaining_usd: 10,
        resets_at: '2026-10-01',
        configured: false,
      },
    });
    expect(screen.getByText(/operator still needs to configure/)).toBeTruthy();
  });
});
