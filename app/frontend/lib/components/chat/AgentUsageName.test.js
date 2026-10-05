import { render, screen, waitFor } from '@testing-library/svelte';
import { loadAgentWeeklyRemaining } from '$lib/agent-subscription-usage';
import AgentUsageName from './AgentUsageName.svelte';

vi.mock('$lib/agent-subscription-usage', async (importOriginal) => ({
  ...(await importOriginal()),
  loadAgentWeeklyRemaining: vi.fn(),
}));

const props = {
  accountId: 'account',
  agent: { id: 'resident', name: 'Resident' },
  mobileGauge: true,
  showUsage: true,
};

test.each([
  [100, 'bg-gray-400'],
  [50, 'bg-gray-400'],
  [49.9, 'bg-gray-600'],
  [25, 'bg-gray-600'],
  [24.9, 'bg-amber-500'],
  [10, 'bg-amber-500'],
  [9.9, 'bg-red-500'],
  [0, 'bg-red-500'],
])('renders %s%% remaining bottom-up in %s', async (remaining, colour) => {
  loadAgentWeeklyRemaining.mockResolvedValue(remaining);
  const { container } = render(AgentUsageName, props);
  await waitFor(() => expect(container.querySelector('[data-subscription-gauge]')).not.toBeNull());
  const gauge = container.querySelector('[data-subscription-gauge]');
  expect(gauge).toHaveClass('md:hidden', 'bg-gray-200');
  expect(gauge).toHaveAttribute('aria-hidden', 'true');
  expect(gauge.firstElementChild).toHaveClass('bottom-0', colour);
  expect(gauge.firstElementChild.style.height).toBe(`${remaining}%`);
  expect(container.querySelector('.sr-only')).toHaveTextContent(`Resident (${remaining}% left)`);
  expect(container.querySelector('.md\\:inline')).toHaveTextContent(`Resident (${remaining}% left)`);
});

test('omits unknown usage rather than displaying an empty gauge', async () => {
  loadAgentWeeklyRemaining.mockResolvedValue(null);
  const { container } = render(AgentUsageName, props);
  await waitFor(() => expect(loadAgentWeeklyRemaining).toHaveBeenCalled());
  expect(container.querySelector('[data-subscription-gauge]')).toBeNull();
  expect(container.querySelector('.sr-only')).toHaveTextContent('Resident');
});

test('leaves the picker name as text without a mobile gauge', async () => {
  loadAgentWeeklyRemaining.mockResolvedValue(80);
  const { container } = render(AgentUsageName, { ...props, mobileGauge: false });
  expect(await screen.findByText('Resident (80% left)')).toBeInTheDocument();
  expect(container.querySelector('[data-subscription-gauge]')).toBeNull();
});
