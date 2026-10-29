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

test('a row replaced while it plays is not marked heard by the old audio ending', async () => {
  const listing = (digest) => ({
    samples: [sample({ digest, audio_url: `/a/1?digest=${digest}` })],
    total: 1,
    page: 1,
    pages: 1,
    state_counts: { review: 1 },
    other_namings: 0,
    preparable: 0,
    learning: 'Learning enabled',
    print: 'Waiting for validation',
  });
  serve(listing('d1'));
  const { container, rerender } = render(VoiceSamples, { base: '/v', name: 'Ann', version: 'one' });
  let row = await screen.findByTestId('voice-sample');
  const audio = container.querySelector('audio');
  audio.play = vi.fn(() => Promise.resolve());
  audio.pause = vi.fn();
  await fireEvent.click(within(row).getByTestId('sample-play'));
  expect(audio.getAttribute('src')).toBe('/a/1?digest=d1');

  // A same-speaker rebuild lands mid-play: the row now carries D2.
  serve(listing('d2'));
  await rerender({ base: '/v', name: 'Ann', version: 'two' });
  await waitFor(() => expect(globalThis.fetch).toHaveBeenCalled());
  row = await screen.findByTestId('voice-sample');
  await waitFor(() => expect(audio.pause).toHaveBeenCalled());
  await fireEvent.ended(audio); // D1 finishing must not count for D2.
  expect(within(row).getByRole('button', { name: 'Accept' })).toBeDisabled();

  await fireEvent.click(within(row).getByTestId('sample-play'));
  expect(audio.getAttribute('src')).toBe('/a/1?digest=d2');
  await fireEvent.ended(audio);
  await waitFor(() => expect(within(row).getByRole('button', { name: 'Accept' })).toBeEnabled());
});

const listing = (samples) => ({
  samples,
  total: samples.length,
  page: 1,
  pages: 1,
  state_counts: { review: samples.length },
  other_namings: 0,
  preparable: 0,
  learning: 'Learning enabled',
  print: 'Waiting for validation',
});

// Fetch stub whose PATCH waits until the test settles it.
function serveSlowSave(body) {
  let settle;
  const saved = new Promise((resolve) => (settle = resolve));
  globalThis.fetch = vi.fn(async (url, options = {}) => {
    if (!options.method) return { ok: true, json: async () => body };
    const ok = await saved;
    return {
      ok,
      json: async () => (ok ? { saved: true } : { error: 'This sample changed. Reload, listen again and retry.' }),
    };
  });
  return settle;
}

async function hearAndAccept(container, row) {
  const audio = container.querySelector('audio');
  audio.play = vi.fn(() => Promise.resolve());
  audio.pause = vi.fn();
  await fireEvent.click(within(row).getByTestId('sample-play'));
  await fireEvent.ended(audio);
  const accept = within(row).getByRole('button', { name: 'Accept' });
  await waitFor(() => expect(accept).toBeEnabled());
  await fireEvent.click(accept);
}

test('accept shows at once, moves the row to the end and leaves the next one playable', async () => {
  const settle = serveSlowSave(
    listing([sample(), sample({ id: 's2', digest: 'd2', audio_url: '/a/2', recording_title: 'Second' })])
  );
  const onChanged = vi.fn();
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann', onChanged });
  let rows = await screen.findAllByTestId('voice-sample');
  await hearAndAccept(container, rows[0]);

  // Before the server answers: s1 is last, shown confirmed and saving; s2 is free.
  rows = screen.getAllByTestId('voice-sample');
  expect(within(rows[0]).getByText('Second')).toBeInTheDocument();
  expect(within(rows[1]).getByTestId('sample-inclusion')).toHaveTextContent('Confirmed · saving…');
  expect(within(rows[1]).getByRole('button', { name: 'Reject' })).toBeDisabled();
  expect(within(rows[0]).getByTestId('sample-play')).toBeEnabled();
  expect(within(rows[0]).getByRole('button', { name: 'Reject' })).toBeEnabled();
  const audio = container.querySelector('audio');
  await fireEvent.click(within(rows[0]).getByTestId('sample-play'));
  expect(audio.getAttribute('src')).toBe('/a/2');
  expect(onChanged).not.toHaveBeenCalled();

  settle(true);
  await waitFor(() => expect(onChanged).toHaveBeenCalled());
  await waitFor(() =>
    expect(within(screen.getAllByTestId('voice-sample')[1]).getByTestId('sample-inclusion')).not.toHaveTextContent(
      'saving'
    )
  );
});

test('rejecting the sample that is playing stops it; rejecting another leaves it sounding', async () => {
  serveSlowSave(listing([sample(), sample({ id: 's2', digest: 'd2', audio_url: '/a/2', recording_title: 'Second' })]));
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann' });
  let rows = await screen.findAllByTestId('voice-sample');
  const audio = container.querySelector('audio');
  audio.play = vi.fn(() => Promise.resolve());
  audio.pause = vi.fn();

  // s1 sounds; rejecting s2 does not touch the player.
  await fireEvent.click(within(rows[0]).getByTestId('sample-play'));
  await fireEvent.play(audio);
  await fireEvent.playing(audio);
  expect(within(rows[0]).getByTestId('sample-play')).toHaveAccessibleName(/^Pause sample/);
  await fireEvent.click(within(rows[1]).getByRole('button', { name: 'Reject' }));
  expect(audio.pause).not.toHaveBeenCalled();
  expect(within(rows[0]).getByTestId('sample-play')).toHaveAccessibleName(/^Pause sample/);

  // Rejecting s1 itself stops it at once, before the server has answered.
  await fireEvent.click(within(rows[0]).getByRole('button', { name: 'Reject' }));
  expect(audio.pause).toHaveBeenCalledTimes(1);
  await fireEvent.pause(audio);
  rows = screen.getAllByTestId('voice-sample');
  const first = rows.find((row) => within(row).queryByText('Synthetic meeting'));
  expect(within(first).getByTestId('sample-play')).toHaveAccessibleName(/^Play sample/);
  expect(within(first).getByTestId('sample-inclusion')).toHaveTextContent('saving');
});

test('a refused accept puts the row back with the reason', async () => {
  const settle = serveSlowSave(listing([sample(), sample({ id: 's2', digest: 'd2', recording_title: 'Second' })]));
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann' });
  const rows = await screen.findAllByTestId('voice-sample');
  await hearAndAccept(container, rows[0]);
  expect(within(screen.getAllByTestId('voice-sample')[1]).getByTestId('sample-inclusion')).toHaveTextContent('saving');

  settle(false);
  expect(await screen.findByRole('alert')).toHaveTextContent('This sample changed');
  const after = screen.getAllByTestId('voice-sample');
  expect(within(after[0]).getByText('Synthetic meeting')).toBeInTheDocument();
  expect(within(after[0]).getByTestId('sample-inclusion')).toHaveTextContent('Needs review');
});

test('another voice loads at once, not behind a slow request for the previous one', async () => {
  let releaseA;
  const heldA = new Promise((resolve) => (releaseA = resolve));
  globalThis.fetch = vi.fn(async (url) => {
    if (url.startsWith('/a/')) await heldA;
    const id = url.startsWith('/a/') ? 'a1' : 'b1';
    return { ok: true, json: async () => listing([sample({ id, recording_title: `Voice ${id}` })]) };
  });
  const { rerender } = render(VoiceSamples, { base: '/a', name: 'Ann' });
  await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledWith('/a/samples?page=1', expect.anything()));

  await rerender({ base: '/b', name: 'Bea' });
  await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledWith('/b/samples?page=1', expect.anything()));
  expect(await screen.findByText('Voice b1')).toBeInTheDocument();

  // A answering late changes nothing for B.
  releaseA();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(screen.getByText('Voice b1')).toBeInTheDocument();
  expect(screen.queryByText('Voice a1')).not.toBeInTheDocument();
  expect(screen.queryByText('Loading samples…')).not.toBeInTheDocument();
});

test('a play interrupted by a second click shows loading, then nothing red', async () => {
  serve(listing([sample(), sample({ id: 's2', digest: 'd2', audio_url: '/a/2' })]));
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann' });
  const [row] = await screen.findAllByTestId('voice-sample');
  const audio = container.querySelector('audio');
  let refuse;
  audio.play = vi.fn(() => {
    Object.defineProperty(audio, 'paused', { value: false, configurable: true });
    return new Promise((_resolve, reject) => (refuse = reject));
  });
  audio.pause = vi.fn(() => {
    Object.defineProperty(audio, 'paused', { value: true, configurable: true });
    refuse(
      Object.assign(new Error('The play() request was interrupted by a call to pause().'), { name: 'AbortError' })
    );
  });
  const play = within(row).getByTestId('sample-play');
  await fireEvent.click(play);
  await fireEvent.play(audio);
  expect(play).toHaveAttribute('aria-busy', 'true');
  expect(play).toHaveAccessibleName(/^Loading sample/);

  await fireEvent.click(play); // Still silent: the person clicks again.
  await fireEvent.pause(audio);
  await Promise.resolve();
  expect(screen.queryByRole('alert')).toBeNull();
  expect(play).toHaveAttribute('aria-busy', 'false');

  await fireEvent.click(play);
  await fireEvent.play(audio);
  await fireEvent.playing(audio);
  expect(play).toHaveAttribute('aria-busy', 'false');
  expect(play).toHaveAccessibleName(/^Pause sample/);
});

test('a real playback failure is still reported', async () => {
  serve(listing([sample()]));
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann' });
  const row = await screen.findByTestId('voice-sample');
  const audio = container.querySelector('audio');
  audio.play = vi.fn(() => Promise.reject(Object.assign(new Error('no source'), { name: 'NotSupportedError' })));
  await fireEvent.click(within(row).getByTestId('sample-play'));
  expect(await screen.findByRole('alert')).toHaveTextContent('could not be played');
});

test('the next samples are asked to be cut ahead, once each', async () => {
  const many = Array.from({ length: 10 }, (_, index) =>
    sample({ id: `s${index + 1}`, digest: `d${index + 1}`, audio_url: `/a/${index + 1}` })
  );
  serve(listing([...many, sample({ id: 'upload-u1', digest: 'u', audio_url: '/a/u' })]));
  const { container } = render(VoiceSamples, { base: '/v', name: 'Ann' });
  await screen.findAllByTestId('voice-sample');
  const warms = () =>
    globalThis.fetch.mock.calls
      .filter(([url]) => url === '/v/samples/warm')
      .map(([, options]) => JSON.parse(options.body).ids);
  const first = many.slice(0, 8).map((row) => row.id);
  await waitFor(() => expect(warms()).toEqual([first]));

  const audio = container.querySelector('audio');
  audio.play = vi.fn(() => Promise.resolve());
  const rows = screen.getAllByTestId('voice-sample');
  await fireEvent.click(within(rows[1]).getByTestId('sample-play'));
  expect(warms()).toEqual([first, ['s9', 's10']]);
  await fireEvent.click(within(rows[2]).getByTestId('sample-play'));
  expect(warms()).toHaveLength(2);
});

test('with twenty included, candidates are not asked about and nothing invites pruning', async () => {
  serve({
    ...listing([
      sample({ id: 's1', state: 'spare', included: false }),
      sample({ id: 's2', state: 'removed', included: false, digest: 'd2', audio_url: '/a/2' }),
    ]),
    state_counts: { spare: 1, removed: 1 },
    full: true,
  });
  render(VoiceSamples, { base: '/v', name: 'Ann' });
  const rows = await screen.findAllByTestId('voice-sample');
  expect(within(rows[0]).getByTestId('sample-inclusion')).toHaveTextContent('Not needed');
  for (const row of rows) expect(within(row).queryByTestId('sample-accept')).toBeNull();
  expect(screen.getByText(/Twenty samples are included/)).toBeInTheDocument();
  expect(screen.queryByText(/Accept after playing/)).toBeNull();
  const warm = globalThis.fetch.mock.calls.find(([url]) => url === '/v/samples/warm');
  expect(warm).toBeUndefined();
});
