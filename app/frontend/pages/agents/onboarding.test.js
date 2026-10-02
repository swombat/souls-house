import { render, screen } from '@testing-library/svelte';
import Onboarding from './onboarding.svelte';
vi.mock('$lib/use-sync', () => ({ useSync: vi.fn() }));

const agent = {
  id: 'resident',
  name: 'Resident',
  runtime: 'external',
  health_state: 'healthy',
  orientation_last_error: 'RAW PROVIDER ERROR: private diagnostic',
};

test('missing inference shows plain instructions and an edit link instead of raw errors or retry', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: {
      ...agent,
      inference_setup_message: 'Edit the resident and set up credentials before asking them to respond.',
    },
  });
  expect(screen.getByRole('status')).toHaveTextContent('set up credentials');
  expect(screen.getByRole('link', { name: 'Edit Resident' })).toHaveAttribute(
    'href',
    '/accounts/account/residents/resident/edit'
  );
  expect(screen.queryByText(agent.orientation_last_error)).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Try orientation again' })).not.toBeInTheDocument();
});

test('other orientation failures use a plain explanation without raw diagnostics', () => {
  render(Onboarding, { account: { id: 'account' }, agent });
  expect(screen.getByText('Their first wake did not complete')).toBeVisible();
  expect(screen.queryByText(agent.orientation_last_error)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Try orientation again' })).toBeEnabled();
});
