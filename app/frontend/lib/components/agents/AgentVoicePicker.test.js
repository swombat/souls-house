import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
import AgentVoicePicker from './AgentVoicePicker.svelte';

vi.mock('@inertiajs/svelte', () => ({ router: { patch: vi.fn() } }));

const voices = [
  { voice_id: 'std-aria', name: 'Aria', description: 'Bright.', labels: { accent: 'american' } },
  { voice_id: 'std-brian', name: 'Brian', description: 'Deep.', labels: { accent: 'british' } },
];

function voiceProp(current) {
  return {
    current_voice_id: current,
    voices_path: '/accounts/a/agents/r/voices',
    update_path: '/accounts/a/agents/r/voice',
    preview_path_template: '/accounts/a/agents/r/voice_preview/VOICE_ID',
  };
}

beforeEach(() => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => ({ ok: true, json: async () => ({ voices }) }))
  );
});

afterEach(() => vi.unstubAllGlobals());

async function loaded(current = 'std-aria') {
  const view = render(AgentVoicePicker, { voice: voiceProp(current) });
  await screen.findByRole('option', { name: /Brian/ });
  return view;
}

test('Preview renders again on a repeat press, after the first one has played', async () => {
  await loaded();
  const button = screen.getByRole('button', { name: 'Preview' });

  await fireEvent.click(button);
  const first = screen.getByTestId('voice-preview-audio');
  expect(first.getAttribute('src')).toBe('/accounts/a/agents/r/voice_preview/std-aria');
  expect(screen.getByRole('button', { name: 'Rendering…' })).toBeDisabled();
  await fireEvent(first, new Event('canplay'));

  await fireEvent.click(screen.getByRole('button', { name: 'Preview' }));
  const second = screen.getByTestId('voice-preview-audio');
  expect(second).not.toBe(first);
  await fireEvent(second, new Event('canplay'));
  expect(screen.getByRole('button', { name: 'Preview' })).not.toBeDisabled();
});

test('a failed preview can be retried and the retry gets a fresh element', async () => {
  await loaded();
  await fireEvent.click(screen.getByRole('button', { name: 'Preview' }));
  const failed = screen.getByTestId('voice-preview-audio');
  await fireEvent(failed, new Event('error'));
  expect(screen.getByText('The preview couldn’t be rendered just now.')).toBeInTheDocument();

  await fireEvent.click(screen.getByRole('button', { name: 'Preview' }));
  const retry = screen.getByTestId('voice-preview-audio');
  expect(retry).not.toBe(failed);
  expect(screen.queryByText('The preview couldn’t be rendered just now.')).not.toBeInTheDocument();
  await fireEvent(retry, new Event('canplay'));
  expect(screen.getByRole('button', { name: 'Preview' })).not.toBeDisabled();
});

test('a voice saved elsewhere (the resident chose one) shows here, so changing it back is possible', async () => {
  const view = await loaded('std-aria');
  const select = screen.getByRole('combobox');
  expect(select.value).toBe('std-aria');

  await view.rerender({ voice: voiceProp('std-brian') });
  await waitFor(() => expect(select.value).toBe('std-brian'));
  expect(screen.getByRole('button', { name: 'Use this voice' })).toBeDisabled();

  await fireEvent.change(select, { target: { value: 'std-aria' } });
  expect(screen.getByRole('button', { name: 'Use this voice' })).not.toBeDisabled();
});

test('an unsaved pick is not overwritten when the saved voice changes underneath', async () => {
  const view = await loaded('std-aria');
  const select = screen.getByRole('combobox');
  await fireEvent.change(select, { target: { value: '' } });

  await view.rerender({ voice: voiceProp('std-brian') });
  expect(select.value).toBe('');
  expect(screen.getByRole('button', { name: 'Remove voice' })).not.toBeDisabled();
});
