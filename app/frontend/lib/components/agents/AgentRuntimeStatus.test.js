import { render, screen } from '@testing-library/svelte';
import { vi } from 'vitest';
import AgentRuntimeStatus from './AgentRuntimeStatus.svelte';

vi.mock('@inertiajs/svelte', () => ({ router: { post: vi.fn() } }));

const since = '2026-10-28T22:04:00Z';

test('says nothing while the resident is well', () => {
  render(AgentRuntimeStatus, { agent: { name: 'Claude', health_state: 'healthy' } });
  expect(screen.queryByTestId('runtime-status')).not.toBeInTheDocument();
});

test('an unanswered runtime says since when and offers the restart', () => {
  render(AgentRuntimeStatus, {
    agent: {
      name: 'Claude',
      health_state: 'unhealthy',
      health_failure_kind: 'unanswered',
      health_failing_since: since,
    },
    sandboxRecreationUrl: '/accounts/a/agents/c/sandbox_recreation',
    canRestart: true,
  });
  const card = screen.getByTestId('runtime-status');
  expect(card).toHaveTextContent("Claude isn't responding right now.");
  expect(card).toHaveTextContent('Since');
  expect(card).toHaveTextContent('Restarting usually fixes it');
  expect(screen.getByRole('button', { name: 'Restart' })).toBeInTheDocument();
});

test('a crash loop is named as one, and the restart is not sold as the fix', () => {
  render(AgentRuntimeStatus, {
    agent: {
      name: 'Claude',
      health_state: 'unhealthy',
      health_failure_kind: 'restarting',
      health_failing_since: since,
    },
    sandboxRecreationUrl: '/accounts/a/agents/c/sandbox_recreation',
    canRestart: true,
  });
  const card = screen.getByTestId('runtime-status');
  expect(card).toHaveTextContent("Claude's runtime keeps restarting.");
  expect(card).toHaveTextContent('may not help');
  expect(card).not.toHaveTextContent('usually fixes it');
});
