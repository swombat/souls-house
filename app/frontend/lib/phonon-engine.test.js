import { get } from 'svelte/store';
import { beforeEach, expect, test, vi } from 'vitest';
import {
  PhononError,
  describeFailure,
  loadPhonon,
  phononState,
  resetPhononForTests,
  synthesize,
  voiceFor,
} from './phonon-engine';

// The library is never imported here: each test hands loadPhonon an importer
// that returns a fake Phonon, so what is asserted is what this module asks of
// the library (model, backend, progress) and what it tells the person.
const DELIA = 'nGzMHMPAWGaJFHOo';
const gpu = {};

function fakeModel({ lost = new Promise(() => {}), speak } = {}) {
  return {
    lost,
    speak: vi.fn(speak ?? (async () => ({ audio: new Float32Array(48_000), sampleRate: 24_000 }))),
  };
}

function fakeLibrary(load) {
  const Phonon = { load: vi.fn(load) };
  return { Phonon, importer: vi.fn(async () => ({ Phonon })) };
}

// Every state the store passes through, in order, from now on.
function recordStates() {
  const seen = [];
  const stop = phononState.subscribe((s) => seen.push({ ...s }));
  seen.shift(); // the value at subscription time
  return { seen, stop };
}

const settle = async () => {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
};

beforeEach(() => resetPhononForTests());

test('without WebGPU the load fails at once, says why, and downloads nothing', async () => {
  const { importer } = fakeLibrary(async () => fakeModel());
  const failure = await loadPhonon({ importer, gpu: undefined }).catch((e) => e);
  expect(failure).toBeInstanceOf(PhononError);
  expect(failure.kind).toBe('no_webgpu');
  expect(get(phononState).status).toBe('error');
  expect(get(phononState).error).toMatch(/needs WebGPU/);
  expect(importer).not.toHaveBeenCalled();
});

test('a load asks for the WebGPU backend only (no CPU fallback), reports progress, and the model is loaded once', async () => {
  const model = fakeModel();
  const { Phonon, importer } = fakeLibrary(async ({ progress }) => {
    progress(50);
    progress(100);
    return model;
  });
  const { seen, stop } = recordStates();
  expect(await loadPhonon({ importer, gpu })).toBe(model);
  stop();

  const options = Phonon.load.mock.calls[0][0];
  expect(options.model).toBe('phonon-31m-en');
  expect(options.backend).toBe('webgpu');
  // Other fields (the persistence answer) also update the store; only changes
  // of status or progress are steps.
  const steps = seen
    .map(({ status, progress }) => [status, progress])
    .filter((step, i, all) => i === 0 || step.join() !== all[i - 1].join());
  expect(steps.slice(steps.findIndex(([s]) => s === 'downloading'))).toEqual([
    ['downloading', 50],
    ['initialising', 100],
    ['ready', 100],
  ]);

  expect(await loadPhonon({ importer, gpu })).toBe(model);
  expect(Phonon.load).toHaveBeenCalledTimes(1);
});

test('two requests during one load share it', async () => {
  let finish;
  const model = fakeModel();
  const { Phonon, importer } = fakeLibrary(() => new Promise((resolve) => (finish = () => resolve(model))));
  const first = loadPhonon({ importer, gpu });
  const second = loadPhonon({ importer, gpu });
  await settle();
  finish();
  expect(await Promise.all([first, second])).toEqual([model, model]);
  expect(Phonon.load).toHaveBeenCalledTimes(1);
});

test('a failed download says so, and the next request tries again', async () => {
  const model = fakeModel();
  const { Phonon, importer } = fakeLibrary(async () => {
    throw new Error('The voice model could not download (404).');
  });
  const failure = await loadPhonon({ importer, gpu }).catch((e) => e);
  expect(failure).toBeInstanceOf(PhononError);
  expect(failure.kind).toBe('download');
  expect(failure.cause.message).toMatch(/404/);
  expect(get(phononState)).toMatchObject({ status: 'error', error: expect.stringMatching(/didn't download \(HTTP 404\)/) });

  Phonon.load.mockImplementation(async () => model);
  expect(await loadPhonon({ importer, gpu })).toBe(model);
  expect(Phonon.load).toHaveBeenCalledTimes(2);
  expect(get(phononState).status).toBe('ready');
});

test('persistent storage is asked for once, and the answer is recorded', async () => {
  const storage = { persisted: vi.fn(async () => false), persist: vi.fn(async () => true) };
  const { Phonon, importer } = fakeLibrary(async () => {
    throw new Error('Failed to fetch');
  });
  await loadPhonon({ importer, gpu, storage }).catch(() => {});
  await settle();
  expect(get(phononState).persisted).toBe(true);
  await loadPhonon({ importer, gpu, storage }).catch(() => {});
  await settle();
  expect(Phonon.load).toHaveBeenCalledTimes(2);
  expect(storage.persist).toHaveBeenCalledTimes(1);
});

test('a browser that refuses persistence is recorded as not persisted', async () => {
  const storage = { persisted: vi.fn(async () => false), persist: vi.fn(async () => false) };
  const { importer } = fakeLibrary(async () => fakeModel());
  await loadPhonon({ importer, gpu, storage });
  await settle();
  expect(get(phononState).persisted).toBe(false);
});

test('a lost GPU device puts the state in error, and the next request loads the model again', async () => {
  let loseDevice;
  const first = fakeModel({ lost: new Promise((resolve) => (loseDevice = resolve)) });
  const second = fakeModel();
  const { Phonon, importer } = fakeLibrary(async () => first);
  await loadPhonon({ importer, gpu });
  loseDevice();
  await settle();
  expect(get(phononState)).toMatchObject({ status: 'error', error: expect.stringMatching(/went away/) });

  Phonon.load.mockImplementation(async () => second);
  expect(await loadPhonon({ importer, gpu })).toBe(second);
  expect(Phonon.load).toHaveBeenCalledTimes(2);
});

test('speaking uses the chosen voice, passes the abort signal on, and returns a WAV with its duration', async () => {
  const model = fakeModel();
  const signal = new AbortController().signal;
  const result = await synthesize('Hello there.', { voice: 'NbpkqMVS3CJeq2j8', signal, load: async () => model });
  expect(model.speak).toHaveBeenCalledWith('Hello there.', { voice: 'NbpkqMVS3CJeq2j8', signal });
  expect(result.blob).toBeInstanceOf(Blob);
  expect(result.blob.type).toBe('audio/wav');
  expect(result.blob.size).toBe(44 + 48_000 * 2);
  expect(result.duration).toBe(2);
});

test('an unknown voice is spoken in Delia\'s voice', async () => {
  const model = fakeModel();
  await synthesize('Hi.', { voice: 'no-such-voice', load: async () => model });
  expect(model.speak.mock.calls[0][1].voice).toBe(DELIA);
  expect(voiceFor(undefined).name).toBe('Delia');
});

test('a failure while speaking becomes a PhononError the person can read', async () => {
  const model = fakeModel({
    speak: async () => {
      throw new Error('shader compile failed');
    },
  });
  const failure = await synthesize('Hi.', { load: async () => model }).catch((e) => e);
  expect(failure).toBeInstanceOf(PhononError);
  expect(failure.kind).toBe('failed');
  expect(failure.message).toBe("Phonon couldn't speak: shader compile failed.");
  expect(failure.cause.message).toBe('shader compile failed');
});

test('a signal already aborted when the model is ready stops before speaking', async () => {
  const model = fakeModel();
  const controller = new AbortController();
  controller.abort();
  const failure = await synthesize('Hi.', { signal: controller.signal, load: async () => model }).catch((e) => e);
  expect(failure.name).toBe('AbortError');
  expect(model.speak).not.toHaveBeenCalled();
});

test('failures are described by cause', () => {
  expect(describeFailure(Object.assign(new Error('x'), { name: 'AbortError' })).kind).toBe('aborted');
  expect(describeFailure(new Error('no WebGPU adapter')).kind).toBe('no_webgpu');
  expect(describeFailure(new Error('GPU device was lost')).kind).toBe('device_lost');
  expect(describeFailure(new Error('NetworkError when attempting to fetch')).kind).toBe('download');
});
