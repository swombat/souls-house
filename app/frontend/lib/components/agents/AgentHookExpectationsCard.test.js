import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import Card from './AgentHookExpectationsCard.svelte';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function payload(expectations = {}, latestRun = null) {
  return {
    hook_expectations: expectations,
    events: ['session_start', 'before_turn', 'stop'],
    states: ['expected', 'off'],
    labels: { session_start: 'wake (session_start)', before_turn: 'before_turn', stop: 'stop' },
    latest_run: latestRun,
  };
}

test('shows each event, the latest warning and hooks, ids and status only', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () =>
        payload(
          { session_start: { state: 'expected', source: 'observed', at: '2026-11-14T08:00:00Z' } },
          {
            id: 1,
            hook_warning: 'The wake (session_start) hook lume-wake is missing.',
            hooks: { status: 'ok', hooks: [{ id: 'lume-recall', event: 'before_turn', enabled: true, approved: false }] },
          },
        ),
    }),
  );
  render(Card, { url: '/x', agentName: 'Lume' });

  await screen.findByTestId('hook-expectations-card');
  expect(screen.getByTestId('hook-expectation-session_start').textContent).toContain('Expected');
  expect(screen.getByTestId('hook-expectation-session_start').textContent).toContain('seen on a run');
  expect(screen.getByTestId('hook-expectation-stop').textContent).toContain('Not set');
  expect(screen.getByTestId('hook-expectations-warning').textContent).toContain('lume-wake is missing');
  expect(screen.getByTestId('hook-expectations-latest').textContent).toContain('lume-recall');
  expect(screen.getByTestId('hook-expectations-latest').textContent).toContain('not approved');
});

test('turning an event off patches it and shows the saved state', async () => {
  const fetchMock = vi
    .fn()
    .mockResolvedValueOnce({ ok: true, json: async () => payload({ stop: { state: 'expected', source: 'observed' } }) })
    .mockResolvedValueOnce({ ok: true, json: async () => payload({ stop: { state: 'off', source: 'owner' } }) });
  vi.stubGlobal('fetch', fetchMock);
  render(Card, { url: '/x', agentName: 'Lume' });

  await fireEvent.click(await screen.findByTestId('hook-expectation-stop-off'));

  await waitFor(() => expect(screen.getByTestId('hook-expectation-stop').textContent).toContain('removed on purpose'));
  const [, init] = fetchMock.mock.calls[1];
  expect(init.method).toBe('PATCH');
  expect(JSON.parse(init.body)).toEqual({ event: 'stop', state: 'off' });
  expect(screen.getByTestId('hook-expectation-stop').textContent).toContain('set by you');
});

test('saves one at a time, so an older reply cannot undo a newer setting', async () => {
  let release;
  const pending = new Promise((resolve) => (release = resolve));
  const fetchMock = vi
    .fn()
    .mockResolvedValueOnce({ ok: true, json: async () => payload() })
    .mockImplementationOnce(() => pending);
  vi.stubGlobal('fetch', fetchMock);
  render(Card, { url: '/x', agentName: 'Lume' });

  await fireEvent.click(await screen.findByTestId('hook-expectation-stop-off'));
  await waitFor(() => expect(screen.getByTestId('hook-expectation-before_turn-off').disabled).toBe(true));
  await fireEvent.click(screen.getByTestId('hook-expectation-before_turn-off'));
  expect(fetchMock).toHaveBeenCalledTimes(2);

  release({ ok: true, json: async () => payload({ stop: { state: 'off', source: 'owner' } }) });
  await waitFor(() => expect(screen.getByTestId('hook-expectation-stop').textContent).toContain('removed on purpose'));
  expect(screen.getByTestId('hook-expectation-before_turn-off').disabled).toBe(false);
});
