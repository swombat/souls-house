import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import WorkCompletionControl from './WorkCompletionControl.svelte';

vi.mock('$lib/cable', () => ({ reloadProps: vi.fn() }));
const props = { accountId: 'house', chat: { id: 'one', work_status: { revision: 2 } } };
const payload = (extra = {}) => ({
  work_status: { state: 'working', revision: 2 },
  completion: null,
  permission: null,
  archived: false,
  ...extra,
});
const response = (body, status = 200) => ({
  ok: status === 200,
  status,
  json: async () => body,
});
const completion = {
  id: 'handoff',
  current: true,
  changes_summary: 'A change',
  result: 'PR 42',
  checks: 'Verified',
  remaining: 'None',
  accepted_at: null,
};
beforeEach(() =>
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => response(payload()))
  )
);
async function open() {
  await fireEvent.click(screen.getByRole('button', { name: 'Completion handoff and review' }));
  await screen.findByRole('form', { name: 'Submit completion handoff' });
}

test('grant is an explicit human action bound to the loaded revision', async () => {
  render(WorkCompletionControl, props);
  await open();
  expect(screen.getByText(/Any status change ends this permission/)).toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Authorise completion and safe closure once' }));
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
  const [url, request] = fetch.mock.calls[1];
  expect(url).toBe('/accounts/house/chats/one/work_completion/grant');
  expect(JSON.parse(request.body)).toEqual({ expected_revision: 2, auto_close: true });
});

test('acceptance names exact handoff and revision, and closure refusal remains visible', async () => {
  fetch.mockResolvedValueOnce(response(payload({ completion })));
  fetch.mockResolvedValueOnce(
    response(
      payload({
        completion: {
          ...completion,
          accepted_at: '2026-11-11',
          closure_blocked: {
            error: 'A promise is still owed',
            scheduled_commitments: [{ resident: 'Mira', headline: 'Finish review' }],
          },
        },
      })
    )
  );
  render(WorkCompletionControl, props);
  await open();
  await fireEvent.click(screen.getByRole('button', { name: 'Accept and close if safe' }));
  await screen.findByText(/Closure blocked: A promise is still owed/);
  expect(screen.getByText('Mira: Finish review')).toBeInTheDocument();
  expect(JSON.parse(fetch.mock.calls[1][1].body)).toEqual({
    id: 'handoff',
    expected_revision: 2,
    auto_close: true,
  });
});

test('new live revision disables acceptance rather than adopting it silently', async () => {
  fetch.mockResolvedValueOnce(response(payload({ completion })));
  const { rerender } = render(WorkCompletionControl, props);
  await open();
  await rerender({ ...props, chat: { ...props.chat, work_status: { revision: 3 } } });
  expect(screen.getByRole('button', { name: 'Accept and close if safe' })).toBeDisabled();
  expect(screen.getByText('Work changed elsewhere. Refresh before deciding.')).toBeInTheDocument();
});

test('failed submission keeps draft and stable idempotency key for an unchanged retry', async () => {
  fetch.mockResolvedValueOnce(response(payload()));
  fetch.mockRejectedValueOnce(new Error('connection lost'));
  fetch.mockRejectedValueOnce(new Error('connection lost'));
  render(WorkCompletionControl, props);
  await open();
  for (const label of ['What changed', 'Where the result is', 'What was checked', 'Anything remaining']) {
    await fireEvent.input(screen.getByLabelText(label), { target: { value: label } });
  }
  const form = screen.getByRole('form', { name: 'Submit completion handoff' });
  await fireEvent.submit(form);
  await screen.findByText('Connection failed. Your draft and retry key are kept.');
  await fireEvent.submit(form);
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(3));
  const first = JSON.parse(fetch.mock.calls[1][1].body);
  expect(JSON.parse(fetch.mock.calls[2][1].body)).toEqual(first);
  expect(first.expected_revision).toBe(2);
  expect(first.request_key).toBeTruthy();
  expect(screen.getByLabelText('What changed')).toHaveValue('What changed');
});
