import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()), reloadProps: vi.fn() }));
import { reloadProps, subscribeToModel } from '$lib/cable';
import Recording from './show.svelte';

const props = {
  account: { id: 'home' },
  recording: { id: 'rec', title: 'Meeting', status: 'ready', words: [], transcript_revision: 1 },
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

test('a refresh never asks for the transcript, a changed transcript revision does once, and a full visit counts as loaded', async () => {
  reloadProps.mockClear();
  const component = render(Recording, props);
  await component.rerender({ ...props, voices: [{ id: 'alice', name: 'Alicia' }] });
  expect(reloadProps).not.toHaveBeenCalled();

  await component.rerender({ ...props, recording: { ...props.recording, transcript_revision: 2 } });
  await waitFor(() => expect(reloadProps).toHaveBeenCalledWith(['words']));
  expect(reloadProps).toHaveBeenCalledTimes(1);

  await component.rerender({
    ...props,
    recording: { ...props.recording, transcript_revision: 3 },
    words: [{ s: 0, e: 100, t: 'Hi', k: 'w', spk: 'speaker_0' }],
  });
  expect(reloadProps).toHaveBeenCalledTimes(1);
});
