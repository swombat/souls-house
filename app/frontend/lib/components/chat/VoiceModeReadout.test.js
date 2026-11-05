import { render, screen } from '@testing-library/svelte';
import { afterEach, expect, test } from 'vitest';
import { accountSpeechEngine } from '$lib/speech-source';
import { phononState, resetPhononForTests } from '$lib/phonon-engine';
import VoiceModeReadout from './VoiceModeReadout.svelte';

// Under Phonon the panel says why it can't speak (or that it is downloading);
// under ElevenLabs, Phonon's state is not the panel's business.
afterEach(() => {
  resetPhononForTests();
  accountSpeechEngine.set('phonon');
});

test("under Phonon the readout shows Phonon's reason it can't speak", () => {
  accountSpeechEngine.set('phonon');
  phononState.set({ status: 'error', progress: 0, error: 'It needs WebGPU.', persisted: null });
  render(VoiceModeReadout, {});
  expect(screen.getByTestId('voice-mode-phonon-status')).toHaveTextContent('It needs WebGPU.');
});

test('under Phonon the first download shows how far it has got', () => {
  phononState.set({ status: 'downloading', progress: 42, error: null, persisted: null });
  render(VoiceModeReadout, {});
  expect(screen.getByTestId('voice-mode-phonon-status')).toHaveTextContent(/42%/);
});

test("under ElevenLabs Phonon's state is not shown", () => {
  accountSpeechEngine.set('elevenlabs');
  phononState.set({ status: 'error', progress: 0, error: 'It needs WebGPU.', persisted: null });
  render(VoiceModeReadout, {});
  expect(screen.queryByTestId('voice-mode-phonon-status')).toBeNull();
});
