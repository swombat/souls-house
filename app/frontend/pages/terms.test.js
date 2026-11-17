import { render } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import Terms from './terms.svelte';

// Cancelling says what End plan does (Billing::Reconcile#propose_end), and no more:
// ending the bill stops renewal, but an earlier change can still leave a final invoice.
test('the Cancelling paragraph promises no more than End plan does', () => {
  const { container } = render(Terms);
  const text = container.textContent.replace(/\s+/g, ' ');
  expect(text).toContain('with End plan');
  expect(text).toContain('The plan will not renew; amounts already owed from earlier changes may still be billed.');
  expect(text).toContain('the unused part of the period is credited against your next bill');
  expect(text).not.toMatch(/not charged again|Stripe's customer portal/);
});
