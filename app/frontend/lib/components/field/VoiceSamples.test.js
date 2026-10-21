import { render, fireEvent, screen, waitFor, within } from '@testing-library/svelte';
import { vi } from 'vitest';
import VoiceSamples from './VoiceSamples.svelte';

const sample = (overrides) => ({
  id: 's1',
  recording_title: 'Synthetic meeting',
  recorded_at: '2026-10-20T10:00:00Z',
  source_url: '/r/1',
  label: 'Speaker 1',
  state: 'review',
  included: true,
  confirmed: false,
  source_current: true,
  segments: [
    [0, 1000],
    [2000, 3500],
  ],
  duration_ms: 2500,
  digest: 'd1',
  audio_url: '/a/1',
  ...overrides,
});

function serve(body) {
  globalThis.fetch = vi.fn(async (url, options = {}) => ({
    ok: true,
    json: async () => (options.method ? { saved: true } : body),
  }));
}

test('compact rows: play, state and accept only after the sample has been played to the end', async () => {
  serve({
    samples: [sample(), sample({ id: 's2', state: 'confirmed', confirmed: true, recording_title: 'Second' })],
    other_namings: 160,
    preparable: 0,
    learning: 'Learning enabled',
    print: 'Waiting for validation',
  });
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann' });
  const rows = await screen.findAllByTestId('voice-sample');
  expect(rows).toHaveLength(2);
  expect(within(rows[0]).getByTestId('sample-inclusion')).toHaveTextContent('Needs review');
  expect(within(rows[0]).getByText(/0:03 · 2 spans/)).toBeInTheDocument();
  const accept = within(rows[0]).getByRole('button', { name: 'Accept' });
  expect(accept).toBeDisabled();
  expect(within(rows[1]).queryByRole('button', { name: 'Accept' })).not.toBeInTheDocument();
  expect(within(rows[1]).getByRole('button', { name: 'Reject' })).toBeEnabled();
  expect(screen.getByText('160 other namings have no usable sample')).toBeInTheDocument();

  const audio = container.querySelector('audio');
  audio.play = vi.fn(() => Promise.resolve());
  audio.pause = vi.fn();
  await fireEvent.click(within(rows[0]).getByTestId('sample-play'));
  expect(audio.getAttribute('src')).toBe('/a/1');
  expect(accept).toBeDisabled();
  await fireEvent.ended(audio);
  await waitFor(() => expect(accept).toBeEnabled());
  await fireEvent.click(accept);
  await waitFor(() =>
    expect(globalThis.fetch).toHaveBeenCalledWith('/v/samples/s1', expect.objectContaining({ method: 'PATCH' }))
  );
  const patch = globalThis.fetch.mock.calls.find(([, options]) => options?.method === 'PATCH')[1];
  expect(JSON.parse(patch.body)).toEqual({ included: true, digest: 'd1' });
});

test('samples without spans offer one prepare button, not a play button', async () => {
  serve({
    samples: [sample({ state: 'not_ready', source_current: false, audio_url: null, segments: null, digest: null })],
    other_namings: 0,
    preparable: 1,
    learning: 'Learning enabled',
    print: 'Recognising: validation passed',
  });
  render(VoiceSamples, { base: '/v', name: 'Ann' });
  const row = await screen.findByTestId('voice-sample');
  expect(within(row).getByTestId('sample-play')).toBeDisabled();
  expect(within(row).queryByRole('button', { name: 'Accept' })).not.toBeInTheDocument();
  expect(within(row).getByRole('button', { name: 'Reject' })).toBeEnabled();
  await fireEvent.click(screen.getByTestId('voice-prepare'));
  await waitFor(() =>
    expect(globalThis.fetch).toHaveBeenCalledWith('/v/samples/prepare', expect.objectContaining({ method: 'POST' }))
  );
});
