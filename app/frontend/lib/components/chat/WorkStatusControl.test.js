import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import WorkStatusControl from './WorkStatusControl.svelte';
import { reloadProps } from '$lib/cable';

vi.mock('$lib/cable', () => ({ reloadProps: vi.fn() }));
const work = (state = null, revision = 0) => ({
  state,
  revision,
  reason: null,
  since: null,
  human_replied_since: null,
});
const props = { accountId: 'house', chat: { id: 'one', work_status: work() } };
const saved = (status = 200, value = work('working', 1)) => ({
  ok: status === 200,
  status,
  json: async () => ({ work_status: value }),
});

beforeEach(() => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => saved())
  );
});

async function open(label = 'Not declared') {
  await fireEvent.click(screen.getByRole('button', { name: `Change work status: ${label}` }));
  return screen.getByRole('form', { name: 'Change work status' });
}

test('unknown is not idle; all six declared statuses are available', async () => {
  render(WorkStatusControl, props);
  expect(screen.getByText('Track work')).toBeInTheDocument();
  await open();
  expect(screen.getAllByRole('option').map((entry) => entry.textContent.trim())).toEqual([
    'Not declared / stop tracking',
    'Working',
    'Ready for review',
    'Needs your input',
    'Blocked',
    'Completed',
    'Idle',
  ]);
});

test('saves exact revision without accepting or archiving and holds acknowledged state against old props', async () => {
  const { rerender } = render(WorkStatusControl, props);
  await open();
  await fireEvent.change(screen.getByLabelText('Status', { exact: true }), { target: { value: 'working' } });
  await fireEvent.input(screen.getByLabelText('Reason (optional)'), { target: { value: ' Building now ' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Save status' }));
  await waitFor(() => expect(screen.queryByRole('form')).not.toBeInTheDocument());
  const [url, request] = fetch.mock.calls[0];
  expect(url).toBe('/accounts/house/chats/one/work_status');
  expect(request.method).toBe('PATCH');
  expect(JSON.parse(request.body)).toEqual({ state: 'working', reason: 'Building now', expected_revision: 0 });
  expect(reloadProps).toHaveBeenCalledWith(['chat', 'chats', 'hidden_chat_ids']);
  await rerender({ ...props, chat: { ...props.chat, work_status: work() } });
  expect(screen.getByRole('button', { name: 'Change work status: Working' })).toBeInTheDocument();
  await rerender({ ...props, chat: { ...props.chat, work_status: work('idle', 2) } });
  expect(screen.getByRole('button', { name: 'Change work status: Idle' })).toBeInTheDocument();
});

test('live updates do not silently replace an open draft or its expected revision', async () => {
  const { rerender } = render(WorkStatusControl, props);
  await open();
  await fireEvent.change(screen.getByLabelText('Status', { exact: true }), { target: { value: 'blocked' } });
  await fireEvent.input(screen.getByLabelText('Reason (required)'), { target: { value: 'Waiting for access' } });
  expect(screen.getByLabelText('Reason (required)')).toBeRequired();
  await rerender({ ...props, chat: { ...props.chat, work_status: work('working', 1) } });
  expect(screen.getByLabelText('Status', { exact: true })).toHaveValue('blocked');
  expect(screen.getByLabelText('Reason (required)')).toHaveValue('Waiting for access');
  fetch.mockResolvedValue(saved(409, work('working', 1)));
  await fireEvent.click(screen.getByRole('button', { name: 'Save status' }));
  await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('changed elsewhere'));
  expect(JSON.parse(fetch.mock.calls[0][1].body).expected_revision).toBe(0);
  expect(screen.getByLabelText('Reason (required)')).toHaveValue('Waiting for access');
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  await open('Working');
  expect(screen.getByLabelText('Status', { exact: true })).toHaveValue('working');
});

test('failure retains the draft and never shows success', async () => {
  render(WorkStatusControl, props);
  await open();
  await fireEvent.change(screen.getByLabelText('Status', { exact: true }), { target: { value: 'idle' } });
  fetch.mockRejectedValue(new Error('offline'));
  await fireEvent.click(screen.getByRole('button', { name: 'Save status' }));
  await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('draft is kept'));
  expect(screen.getByLabelText('Status', { exact: true })).toHaveValue('idle');
});

test('a human reply is visible as evidence, not an automatic resolution', async () => {
  render(WorkStatusControl, {
    ...props,
    chat: { ...props.chat, work_status: { ...work('needs_input', 3), human_replied_since: '2026-11-11T20:00:00Z' } },
  });
  await open('Needs your input');
  expect(screen.getByText(/does not prove the question or blocker is resolved/)).toBeInTheDocument();
});
