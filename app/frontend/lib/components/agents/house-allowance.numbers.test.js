import { render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';

// Four allowances, four constants: each panel states its own, and none is a
// copy of another (negative control: all four differ here).
vi.mock('@inertiajs/svelte', async () => {
  const { readable } = await import('svelte/store');
  return {
    page: readable({
      props: {
        billing_numbers: {
          account_allowance_usd: '11.00',
          trial_allowance_usd: '12.00',
          free_hosting_allowance_usd: '13.00',
          on_the_house_allowance_usd: '14.00',
          trial_days: 14,
          grace_days: 14,
        },
      },
    }),
  };
});

const { default: HouseAllowance } = await import('./house-allowance.svelte');

const plan = { source: 'plan', plan: 'Small', rate: 'standard', limit_usd: 11, remaining_usd: 5, configured: true };

describe('House allowance numbers', () => {
  it('a paid resident: the account allowance, and the on-the-house one it leaves unused', () => {
    render(HouseAllowance, { selectedModel: 'house/claude-haiku-5.5', allowance: { ...plan, resets_at: '2026-12-01' } });
    expect(screen.getByText(/The account gets \$11 a month of house-model use/)).toBeTruthy();
    expect(screen.getByText(/The free\s+\$14 allowance isn't used/)).toBeTruthy();
  });
  it('the free trial: its own amount, then the account allowance after', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { ...plan, trial_ends_at: '2026-11-24T12:00:00Z' },
    });
    expect(screen.getByRole('heading', { name: 'Small · $12 for the free trial' })).toBeTruthy();
    expect(screen.getByText(/allowance becomes \$11 a month/)).toBeTruthy();
  });
  it('free hosting and on the house each state their own', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { source: 'free', limit_usd: 13, remaining_usd: 1, resets_at: '2026-12-01', configured: true },
    });
    expect(screen.getByText(/Free hosting · \$13 per month/)).toBeTruthy();
  });
  it('on the house', () => {
    render(HouseAllowance, {
      selectedModel: 'house/claude-haiku-5.5',
      allowance: { remaining_usd: 2, resets_at: '2026-12-01', configured: true },
    });
    expect(screen.getByText(/On the house · \$14 per month/)).toBeTruthy();
  });
});
