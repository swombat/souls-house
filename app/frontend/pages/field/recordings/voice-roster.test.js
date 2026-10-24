import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()), reloadProps: vi.fn() }));
import { reloadProps, subscribeToModel } from '$lib/cable';
import Recording from './show.svelte';

const props = {
  account: { id: 'home' },
  recording: { id: 'rec', title: 'Meeting', status: 'ready', transcript_revision: 1 },
  transcript: { revision: 1, words: [] },
  speakers: [{ id: 'speaker', speaker_key: 'speaker_0', label: 'Speaker 1', named: false, talk_ms: 0 }],
  voices: [{ id: 'alice', name: 'Alice' }],
};

test('roster uses a separate narrow map, without reloading recording or speakers', async () => {
  const component = render(Recording, props);
  await waitFor(() =>
    expect(subscribeToModel).toHaveBeenCalledWith('FieldVoiceActivity', 'home', [
      'voices',
      'members_without_voice',
      'my_voice_id',
      'recognition_enabled',
    ])
  );
  expect(subscribeToModel).toHaveBeenCalledWith('FieldRecording', 'rec', ['recording', 'speakers']);
  const count = subscribeToModel.mock.calls.length;
  await component.rerender({ ...props, voices: [{ id: 'alice', name: 'Alicia' }] });
  expect(subscribeToModel).toHaveBeenCalledTimes(count);
});

test('an open name picker adopts roster changes without losing its typed name', async () => {
  const component = render(Recording, props);
  await fireEvent.click(screen.getByTestId('speaker-chip'));
  const draft = await screen.findByPlaceholderText('Their name');
  await fireEvent.input(draft, { target: { value: 'Unfinished new name' } });
  expect(screen.getByRole('button', { name: 'Alice', exact: true })).toBeInTheDocument();
  await component.rerender({ ...props, voices: [{ id: 'bob', name: 'Bob' }] });
  expect(screen.queryByRole('button', { name: 'Alice', exact: true })).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Bob', exact: true })).toBeInTheDocument();
  expect(draft).toHaveValue('Unfinished new name');
});

const recordingSubscription = () =>
  subscribeToModel.mock.calls.filter(([model]) => model === 'FieldRecording').at(-1)?.[2];

test('a refresh never asks for the transcript; a revision the page lacks words for asks once, then refreshes carry them until they arrive', async () => {
  reloadProps.mockClear();
  subscribeToModel.mockClear();
  const held = { ...props, transcript: { revision: 1, words: [] } };
  const component = render(Recording, held);
  await component.rerender({ ...held, voices: [{ id: 'alice', name: 'Alicia' }] });
  expect(reloadProps).not.toHaveBeenCalled();
  expect(recordingSubscription()).toEqual(['recording', 'speakers']);

  // The transcript changed: one request now, and the recording's refreshes
  // (including a reconnect's catch-up) carry the transcript while it's missing.
  const changed = { ...held, recording: { ...props.recording, transcript_revision: 2 } };
  await component.rerender(changed);
  await waitFor(() => expect(reloadProps).toHaveBeenCalledWith(['transcript']));
  expect(recordingSubscription()).toEqual(['recording', 'speakers', 'transcript']);

  // That reply is lost; a refresh of the recording alone asks nothing new by
  // itself, and the subscription still carries the transcript.
  const asked = reloadProps.mock.calls.length;
  await component.rerender({ ...changed, recording: { ...changed.recording } });
  expect(reloadProps).toHaveBeenCalledTimes(asked);

  // The words arrive: the subscription goes back to the recording alone.
  await component.rerender({
    ...changed,
    transcript: { revision: 2, words: [{ s: 0, e: 100, t: 'Hi', k: 'w', spk: 'speaker_0' }] },
  });
  await waitFor(() => expect(recordingSubscription()).toEqual(['recording', 'speakers']));
  expect(screen.getByText('Hi')).toBeInTheDocument();
});
