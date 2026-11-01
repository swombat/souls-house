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

function checked() {
  const on = screen.getAllByRole('radio').filter((r) => r.getAttribute('aria-checked') === 'true');
  expect(on).toHaveLength(1);
  return on[0].textContent;
}

async function loaded(current = 'std-aria') {
  const view = render(AgentVoicePicker, { voice: voiceProp(current) });
  await screen.findByRole('radio', { name: /Brian/ });
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
  expect(checked()).toMatch(/Aria/);

  await view.rerender({ voice: voiceProp('std-brian') });
  await waitFor(() => expect(checked()).toMatch(/Brian/));
  expect(screen.getByRole('button', { name: 'Use this voice' })).toBeDisabled();

  await fireEvent.click(screen.getByRole('radio', { name: /Aria/ }));
  expect(screen.getByRole('button', { name: 'Use this voice' })).not.toBeDisabled();
});

test('an unsaved pick is not overwritten when the saved voice changes underneath', async () => {
  const view = await loaded('std-aria');
  await fireEvent.click(screen.getByRole('radio', { name: /No voice/ }));

  await view.rerender({ voice: voiceProp('std-brian') });
  expect(checked()).toMatch(/No voice/);
  expect(screen.getByRole('button', { name: 'Remove voice' })).not.toBeDisabled();
});

test('each voice is a tappable row with its own colour; a row Preview picks and plays that voice', async () => {
  await loaded('std-aria');
  const rows = screen.getAllByTestId('voice-option');
  expect(rows).toHaveLength(3); // No voice, Aria, Brian
  expect(screen.queryByRole('combobox')).not.toBeInTheDocument();

  await fireEvent.click(screen.getByRole('button', { name: 'Preview Brian' }));
  expect(checked()).toMatch(/Brian/);
  expect(screen.getByTestId('voice-preview-audio').getAttribute('src')).toBe(
    '/accounts/a/agents/r/voice_preview/std-brian'
  );
  expect(screen.getByRole('button', { name: 'Use this voice' })).not.toBeDisabled();
  expect(screen.queryByRole('button', { name: 'Preview No voice' })).not.toBeInTheDocument();
});
