import { render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';

// One allowance, the account's (Billing::Allowance): every panel states that
// one number. The old per-resident and per-person keys are absent here, so a
// panel still reading one would print nothing where the amount should be.
vi.mock('@inertiajs/svelte', async () => {
  const { readable } = await import('svelte/store');
  return {
    page: readable({
      props: {
        billing_numbers: { account_allowance_usd: '11.00', trial_days: 14, grace_days: 14 },
      },
    }),
  };
});

const { default: HouseAllowance } = await import('./house-allowance.svelte');

const plan = { source: 'plan', plan: 'Small', rate: 'standard', limit_usd: 11, remaining_usd: 5, configured: true };

describe('House allowance numbers', () => {
  it('a paid resident: the account allowance, and no second one beside it', () => {
    render(HouseAllowance, { selectedModel: 'house/claude-haiku-5.5', allowance: { ...plan, resets_at: '2026-12-01' } });
    expect(screen.getByText(/The account gets \$11 a month of house-model use/)).toBeTruthy();
    expect(screen.queryByText(/allowance isn't used/)).toBeNull();
  });
  it('the free trial: the same amount for the whole trial, then a month of it', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { ...plan, trial_ends_at: '2026-11-24T12:00:00Z' },
    });
    expect(screen.getByRole('heading', { name: 'Small · $11 for the free trial' })).toBeTruthy();
    expect(screen.getByText(/allowance becomes \$11 a month/)).toBeTruthy();
  });
  it('free hosting draws on the account allowance', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { source: 'free', limit_usd: 11, remaining_usd: 1, resets_at: '2026-12-01', configured: true },
    });
    expect(screen.getByText(/Free hosting · the account's \$11 a month/)).toBeTruthy();
    expect(screen.queryByText(/of its own/)).toBeNull();
  });
  it('on the house draws on the account allowance', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { remaining_usd: 2, resets_at: '2026-12-01', configured: true },
    });
    expect(screen.getByText(/On the house · the account's \$11 a month/)).toBeTruthy();
  });
});
