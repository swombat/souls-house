import { render, screen } from '@testing-library/svelte';
import RuntimeSessions from './agent-runtime-sessions.svelte';

test('a session permalink opens output before the collapsed technical breakdown', () => {
  const window = { from: '2026-09-06T00:00:00Z', to: '2026-09-06T06:00:00Z' };
  render(RuntimeSessions, {
    agent: { name: 'Synthetic resident', runtime: 'hosted', account_name: 'Test account' },
    filters: window,
    selected_session_id: 'selected-session',
    tokens: {},
    token_unknown_rows: {},
    report: {
      window,
      filter_options: { trigger_kind: [], provider: [], model: [], session_outcome: [], session_roll_reason: [] },
      summary: { tokens: {}, token_unknown_rows: {} },
      sessions: [
        {
          session_id: 'selected-session',
          tokens: {},
          token_unknown_rows: {},
          telemetry_state: 'complete',
          interactions: [
            { id: 'one', trigger_kind: 'wake', started_at: window.from, tokens: {}, stdout: 'Hello from this wake.' },
          ],
        },
      ],
    },
  });
  const output = screen.getByText('Hello from this wake.');
  expect(output.closest('details')).toHaveAttribute('open');
  const technical = screen.getByText('Technical invocation breakdown');
  expect(technical.closest('details')).not.toHaveAttribute('open');
  expect(output.compareDocumentPosition(technical) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});
