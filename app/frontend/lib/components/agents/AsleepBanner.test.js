import { render, screen } from '@testing-library/svelte';
import AsleepBanner from './AsleepBanner.svelte';

test('says the resident is asleep, that nothing is lost, and offers the way to wake them', () => {
  render(AsleepBanner, { name: 'Aria', billingUrl: '/accounts/a/billing' });
  const banner = screen.getByTestId('asleep-banner');
  expect(banner).toHaveTextContent('Aria is asleep');
  expect(banner).toHaveTextContent('untouched');
  expect(screen.getByRole('link', { name: 'Pay to wake Aria' })).toHaveAttribute('href', '/accounts/a/billing');
});

test('someone who cannot pay sees the state but no pay button', () => {
  render(AsleepBanner, { name: 'Aria', billingUrl: null });
  expect(screen.getByTestId('asleep-banner')).toHaveTextContent('Aria is asleep');
  expect(screen.queryByRole('link')).not.toBeInTheDocument();
});
