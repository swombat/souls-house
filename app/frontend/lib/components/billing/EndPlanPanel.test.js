import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import EndPlanPanel from './EndPlanPanel.svelte';

const account = { id: 'home', name: 'Home' };
const base = { attempt_id: 9, digest: 'dig', resident_name: 'Second', currency: 'usd' };
const del = {
  ...base,
  operation: 'delete',
  next_at: '2026-12-01',
  next_change_cents: -2200,
  next_total_cents: 4000,
  recurring_cents: 5500,
};
const periodEnd = {
  ...base,
  operation: 'period_end',
  ends_at: '2026-12-01',
  next_at: '2026-12-01',
  final_total_cents: 0,
};

const FORBIDDEN = [/nothing more is charged/i, /payment received/i, /cancelled/i];
function refundMentions(text) {
  return (text.match(/refund/gi) || []).length;
}

beforeEach(() => vi.clearAllMocks());
afterEach(cleanup);

describe('EndPlanPanel', () => {
  it('words an immediate end with the amounts', () => {
    render(EndPlanPanel, { account, pending: del });
    const panel = screen.getByTestId('billing-end-confirm');
    expect(panel).toHaveTextContent("End Second's plan");
    expect(panel).toHaveTextContent('Second stops now and sleeps; nothing in their home is deleted.');
    expect(panel).toHaveTextContent(
      "Your next bill on 1 Dec 2026 goes down by $22, to $40: Second's plan isn't renewed, and the unused part of this period comes off as credit."
    );
    expect(panel).toHaveTextContent("Credit stays on the account's bill. It isn't a refund to your card.");
    expect(panel).toHaveTextContent('After that the account pays $55 a month.');
    expect(screen.getByRole('button', { name: "End Second's plan now" })).toBeInTheDocument();
  });

  it('never says the bill goes down when it does not', () => {
    render(EndPlanPanel, { account, pending: { ...del, next_change_cents: 0, next_total_cents: 4000 } });
    const panel = screen.getByTestId('billing-end-confirm');
    expect(panel).not.toHaveTextContent('goes down');
    expect(panel).toHaveTextContent("Your next bill on 1 Dec 2026 is $40. Second's plan isn't renewed.");
  });

  it('words a period-end with nothing more to bill', () => {
    render(EndPlanPanel, { account, pending: periodEnd });
    const panel = screen.getByTestId('billing-end-confirm');
    expect(panel).toHaveTextContent("Second's plan won't renew. Second keeps running until 1 Dec 2026, then sleeps;");
    expect(panel).toHaveTextContent("Stripe's preview shows nothing more to bill on 1 Dec 2026.");
    expect(panel).toHaveTextContent('You can keep the plan any time before then.');
    expect(screen.getByRole('button', { name: "Don't renew Second's plan" })).toBeInTheDocument();
  });

  it('words a period-end with earlier changes still billed', () => {
    render(EndPlanPanel, { account, pending: { ...periodEnd, final_total_cents: 1250 } });
    const panel = screen.getByTestId('billing-end-confirm');
    expect(panel).toHaveTextContent('$12.50 from earlier changes is still billed on 1 Dec 2026.');
    expect(panel).not.toHaveTextContent('nothing more to bill');
  });

  it('never uses forbidden wording', () => {
    for (const pending of [del, periodEnd, { ...periodEnd, final_total_cents: 500 }]) {
      const { container, unmount } = render(EndPlanPanel, { account, pending });
      const text = container.textContent;
      FORBIDDEN.forEach((pattern) => expect(text).not.toMatch(pattern));
      expect(refundMentions(text)).toBe(pending.operation === 'delete' ? 1 : 0);
      unmount();
    }
  });

  it('confirms the attempt and digest, disabled while in flight', async () => {
    render(EndPlanPanel, { account, pending: del });
    await fireEvent.click(screen.getByRole('button', { name: "End Second's plan now" }));
    expect(router.post).toHaveBeenCalledWith(
      '/accounts/home/billing/confirm_end_plan',
      { attempt_id: 9, digest: 'dig' },
      expect.objectContaining({ onFinish: expect.any(Function) })
    );
    expect(screen.getByRole('button', { name: "End Second's plan now" })).toBeDisabled();
  });

  it('Not now goes back to the billing page', async () => {
    render(EndPlanPanel, { account, pending: del });
    await fireEvent.click(screen.getByRole('button', { name: 'Not now' }));
    expect(router.visit).toHaveBeenCalledWith('/accounts/home/billing');
  });
});
