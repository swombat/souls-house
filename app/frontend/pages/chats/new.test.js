import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import { clearLocalDrafts } from '$lib/conversation-draft';
import NewChat from './new.svelte';

const props = {
  user: { id: 'user' },
  account: { id: 'account' },
  agents: [{ id: 'resident', name: 'Resident', active: true }],
};

const key = 'conversation-draft:v1:user:account:new';
beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
});
afterEach(() => vi.unstubAllGlobals());

test('names a draft locally and includes the name when creating the conversation', async () => {
  render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Edit chat title'));
  const title = screen.getAllByRole('textbox').find((input) => input.tagName === 'INPUT');
  await fireEvent.input(title, { target: { value: '  Paulina’s conversation  ' } });
  await fireEvent.keyDown(title, { key: 'Enter' });
  expect(router.post).not.toHaveBeenCalled();
  expect(screen.getByTitle('Edit chat title')).toHaveTextContent('Paulina’s conversation');
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'First message' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  expect(router.post.mock.calls[0][1].get('chat[title]')).toBe('Paulina’s conversation');
});

test('cancelling a draft rename keeps the default title', async () => {
  render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Edit chat title'));
  const title = screen.getAllByRole('textbox').find((input) => input.tagName === 'INPUT');
  await fireEvent.input(title, { target: { value: 'Do not save' } });
  await fireEvent.keyDown(title, { key: 'Escape' });
  expect(screen.getByTitle('Edit chat title')).toHaveTextContent('New Chat');
  expect(router.post).not.toHaveBeenCalled();
});

test('records the first message using the account endpoint and submits its audio', async () => {
  const stop = vi.fn();
  vi.stubGlobal('navigator', {
    mediaDevices: { getUserMedia: vi.fn().mockResolvedValue({ getTracks: () => [{ stop }] }) },
  });
  vi.stubGlobal(
    'MediaRecorder',
    class {
      static isTypeSupported() {
        return true;
      }
      mimeType = 'audio/webm';
      start() {
        this.state = 'recording';
      }
      stop() {
        this.ondataavailable({ data: new Blob(['x'.repeat(2000)]) });
        this.onstop();
      }
    }
  );
  const fetch = vi.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ text: 'Hello from my microphone', audio_signed_id: 'signed-audio' }),
  });
  vi.stubGlobal('fetch', fetch);
  router.post.mockImplementationOnce((_url, body) => {
    const saved = JSON.parse(localStorage.getItem(key));
    expect(saved.message).toBe('Hello from my microphone');
    expect(saved.submissionId).toBe(body.get('draft_submission_id'));
    expect(saved).not.toHaveProperty('audio_signed_id');
  });
  render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Record voice message'));
  await fireEvent.click(await screen.findByTitle('Stop recording'));
  await waitFor(() => expect(router.post).toHaveBeenCalled());
  expect(fetch.mock.calls[0][0]).toBe('/accounts/account/chats/transcription');
  const body = router.post.mock.calls[0][1];
  expect(body.get('message')).toBe('Hello from my microphone');
  expect(body.get('audio_signed_id')).toBe('signed-audio');
  expect(body.getAll('agent_ids[]')).toEqual(['resident']);
  expect(JSON.parse(localStorage.getItem(key)).message).toBe('Hello from my microphone');
  expect(JSON.parse(localStorage.getItem(key)).submissionId).toBe(body.get('draft_submission_id'));
  expect(stop).toHaveBeenCalled();
});

test('saves message synchronously on input, before a tick or reload', async () => {
  const view = render(NewChat, props);
  fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Immediate reload' } });
  expect(JSON.parse(localStorage.getItem(key)).message).toBe('Immediate reload');
  view.unmount();
  render(NewChat, props);
  expect(screen.getByRole('textbox')).toHaveValue('Immediate reload');
});

test('resizes the restored textarea on mount', async () => {
  const height = vi.spyOn(HTMLElement.prototype, 'scrollHeight', 'get').mockReturnValue(180);
  try {
    localStorage.setItem(
      key,
      JSON.stringify({ message: 'Multiline\nrestoration', title: '', selectedAgentIds: ['resident'] })
    );
    render(NewChat, props);
    await waitFor(() => expect(screen.getByRole('textbox')).toHaveStyle({ height: '180px' }));
  } finally {
    height.mockRestore();
  }
});

test('restores title input even before accepting the rename', async () => {
  const view = render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Edit chat title'));
  const input = screen.getAllByRole('textbox').find((element) => element.tagName === 'INPUT');
  fireEvent.input(input, { target: { value: 'Unfinished title' } });
  expect(JSON.parse(localStorage.getItem(key)).title).toBe('Unfinished title');
  view.unmount();
  render(NewChat, props);
  expect(screen.getByTitle('Edit chat title')).toHaveTextContent('Unfinished title');
});

test('restores an empty audience rather than selecting new residents', async () => {
  const view = render(NewChat, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Resident' }));
  expect(JSON.parse(localStorage.getItem(key)).selectedAgentIds).toEqual([]);
  view.unmount();
  render(NewChat, {
    ...props,
    agents: [...props.agents, { id: 'new', name: 'New resident' }],
  });
  expect(screen.getByRole('button', { name: 'Resident' })).toHaveAttribute('aria-pressed', 'false');
  expect(screen.getByRole('button', { name: 'New resident' })).toHaveAttribute('aria-pressed', 'false');
});

test('filters missing residents without expanding the restored audience', () => {
  localStorage.setItem(key, JSON.stringify({ message: 'Keep', title: 'Title', selectedAgentIds: ['gone'] }));
  render(NewChat, props);
  expect(screen.getByRole('button', { name: 'Resident' })).toHaveAttribute('aria-pressed', 'false');
  expect(screen.getByRole('textbox')).toHaveValue('Keep');
  expect(screen.getByRole('button', { name: 'Start conversation' })).toBeDisabled();
});

test('keys the editor by account and user on same-page prop changes', async () => {
  const view = render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'First scope' } });
  await view.rerender({ ...props, account: { id: 'other-account' } });
  expect(screen.getByRole('textbox')).toHaveValue('');
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Other account' } });
  await view.rerender({ ...props, user: { id: 'other-user' } });
  expect(screen.getByRole('textbox')).toHaveValue('');
  await view.rerender(props);
  expect(screen.getByRole('textbox')).toHaveValue('First scope');
});

test('does not persist input without an authenticated user', async () => {
  render(NewChat, { ...props, user: null });
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'No user' } });
  expect(localStorage.length).toBe(0);
  expect(screen.getByText(/Sign in to save/)).toBeInTheDocument();
});

test('retains a refused create across remount and warns about a possible send', async () => {
  const view = render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Do not lose' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  const [, body, callbacks] = router.post.mock.calls[0];
  expect(callbacks.headers).toEqual({ 'X-Draft-User': 'user' });
  callbacks.onSuccess({ props: { flash: {} } });
  callbacks.onFinish();
  view.unmount();
  render(NewChat, props);
  expect(screen.getByRole('textbox')).toHaveValue('Do not lose');
  expect(screen.getByRole('alert')).toHaveTextContent('may already have been sent; check the sidebar');
  expect(JSON.parse(localStorage.getItem(key)).submissionId).toBe(body.get('draft_submission_id'));
});

test.each(['error', 'cancel'])('retains drafts after %s and releases processing', async (outcome) => {
  const view = render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Keep after failure' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  const callbacks = router.post.mock.calls[0][2];
  if (outcome === 'error') callbacks.onError({ message: 'Refused' });
  callbacks.onFinish();
  await waitFor(() => expect(screen.getByRole('button', { name: 'Start conversation' })).not.toBeDisabled());
  view.unmount();
  render(NewChat, props);
  expect(screen.getByRole('textbox')).toHaveValue('Keep after failure');
});

test('requires the exact submitted nonce receipt and copy before clearing', async () => {
  const view = render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Submit' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  const [, body, callbacks] = router.post.mock.calls[0];
  callbacks.onSuccess({ props: { flash: { draft_submission_id: 'unrelated' } } });
  expect(localStorage.getItem(key)).not.toBeNull();
  callbacks.onSuccess({ props: { flash: { draft_submission_id: body.get('draft_submission_id') } } });
  expect(localStorage.getItem(key)).toBeNull();
  view.unmount();
  render(NewChat, props);
  expect(screen.getByRole('textbox')).toHaveValue('');
});

test('a success leaves a newer tab draft untouched, even when its text matches', async () => {
  const view = render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Same text' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  const [, body, callbacks] = router.post.mock.calls[0];
  const newer = JSON.stringify({ message: 'Same text', title: 'New title', selectedAgentIds: [] });
  localStorage.setItem(key, newer);
  callbacks.onSuccess({ props: { flash: { draft_submission_id: body.get('draft_submission_id') } } });
  expect(localStorage.getItem(key)).toBe(newer);
  view.unmount();
  render(NewChat, props);
  expect(screen.getByTitle('Edit chat title')).toHaveTextContent('New title');
});

test('a matching receipt retains title and audience edits made while submitting', async () => {
  const view = render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Original message' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  const [, body, callbacks] = router.post.mock.calls[0];
  await fireEvent.click(screen.getByTitle('Edit chat title'));
  const input = screen.getAllByRole('textbox').find((element) => element.tagName === 'INPUT');
  await fireEvent.input(input, { target: { value: 'Newer title' } });
  await fireEvent.keyDown(input, { key: 'Enter' });
  await fireEvent.click(screen.getByRole('button', { name: 'Resident' }));
  callbacks.onSuccess({ props: { flash: { draft_submission_id: body.get('draft_submission_id') } } });
  callbacks.onFinish();
  view.unmount();
  render(NewChat, props);
  expect(screen.getByRole('textbox')).toHaveValue('Original message');
  expect(screen.getByTitle('Edit chat title')).toHaveTextContent('Newer title');
  expect(screen.getByRole('button', { name: 'Resident' })).toHaveAttribute('aria-pressed', 'false');
});

test('logout suppresses late input and successful-send callbacks', async () => {
  render(NewChat, props);
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Private' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
  const [, body, callbacks] = router.post.mock.calls[0];
  clearLocalDrafts('user');
  callbacks.onSuccess({ props: { flash: { draft_submission_id: body.get('draft_submission_id') } } });
  callbacks.onFinish();
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Late input' } });
  expect(localStorage.getItem(key)).toBeNull();
});

test('warns about blocked storage without preventing submission', async () => {
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
    throw new Error('quota');
  });
  try {
    render(NewChat, props);
    await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'Still usable' } });
    expect(screen.getByRole('alert')).toHaveTextContent('Browser storage is unavailable');
    await fireEvent.click(screen.getByRole('button', { name: 'Start conversation' }));
    expect(router.post).toHaveBeenCalled();
  } finally {
    vi.restoreAllMocks();
  }
});

test('shows recording errors without creating a conversation', async () => {
  vi.stubGlobal('navigator', {
    mediaDevices: { getUserMedia: vi.fn().mockRejectedValue({ name: 'NotAllowedError' }) },
  });
  render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Record voice message'));
  expect(await screen.findByRole('alert')).toHaveTextContent('Microphone access denied');
  expect(router.post).not.toHaveBeenCalled();
});
