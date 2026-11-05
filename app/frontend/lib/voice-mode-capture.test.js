import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { startCapture } from './voice-mode-capture';

// Once getUserMedia has handed over the microphone, any later setup failure
// must give it back: the caller never gets a handle it could stop.
function fakeBrowser({ addModule, createMediaStreamSource } = {}) {
  const track = {
    stopped: false,
    stop() {
      this.stopped = true;
    },
  };
  const stream = { getTracks: () => [track] };
  const contexts = [];
  class FakeContext {
    constructor() {
      this.state = 'running';
      this.sampleRate = 48_000;
      this.closed = false;
      this.audioWorklet = { addModule: addModule || (async () => {}) };
      contexts.push(this);
    }
    createMediaStreamSource() {
      if (createMediaStreamSource) return createMediaStreamSource();
      return { connect() {}, disconnect() {} };
    }
    async close() {
      this.closed = true;
    }
  }
  vi.stubGlobal('navigator', { mediaDevices: { getUserMedia: vi.fn(async () => stream) } });
  vi.stubGlobal('AudioContext', FakeContext);
  vi.stubGlobal(
    'AudioWorkletNode',
    class {
      constructor() {
        this.port = {};
      }
      connect() {}
      disconnect() {}
    }
  );
  return { track, contexts };
}

const createObjectURL = vi.fn(() => 'blob:voice-mode-tap');
const revokeObjectURL = vi.fn();
beforeEach(() => {
  createObjectURL.mockClear();
  revokeObjectURL.mockClear();
  URL.createObjectURL = createObjectURL;
  URL.revokeObjectURL = revokeObjectURL;
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('startCapture', () => {
  test('releases the microphone and closes the context when the worklet fails to load', async () => {
    const { track, contexts } = fakeBrowser({
      addModule: async () => {
        throw new Error('worklet refused');
      },
    });
    await expect(startCapture()).rejects.toThrow('worklet refused');
    expect(track.stopped).toBe(true);
    expect(contexts[0].closed).toBe(true);
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:voice-mode-tap');
  });

  test('releases the microphone when the media source cannot be created', async () => {
    const { track, contexts } = fakeBrowser({
      createMediaStreamSource: () => {
        throw new Error('no source');
      },
    });
    await expect(startCapture()).rejects.toThrow('no source');
    expect(track.stopped).toBe(true);
    expect(contexts[0].closed).toBe(true);
  });

  test('a successful start keeps the microphone until stop', async () => {
    const { track, contexts } = fakeBrowser();
    const handle = await startCapture();
    expect(track.stopped).toBe(false);
    await handle.stop();
    expect(track.stopped).toBe(true);
    expect(contexts[0].closed).toBe(true);
  });
});

// jMapOj: Android mutes the track or suspends the context when the screen goes
// off or another app takes the mic. The capture reports it; the panel decides.
describe('startCapture interruptions', () => {
  test('reports a muted or ended track and a suspended context, and a restore', async () => {
    const { track, contexts } = fakeBrowser();
    track.readyState = 'live';
    const oninterrupt = vi.fn();
    const onrestore = vi.fn();
    const handle = await startCapture({ oninterrupt, onrestore });
    const context = contexts[0];

    track.muted = true;
    track.onmute();
    expect(oninterrupt).toHaveBeenLastCalledWith('muted');
    expect(handle.running).toBe(false);
    track.muted = false;
    track.onunmute();
    expect(onrestore).toHaveBeenCalledTimes(1);
    expect(handle.running).toBe(true);

    context.state = 'suspended';
    context.onstatechange();
    expect(oninterrupt).toHaveBeenLastCalledWith('suspended');
    context.resume = vi.fn(async () => (context.state = 'running'));
    await handle.resume();
    expect(context.resume).toHaveBeenCalled();
    context.onstatechange();
    expect(onrestore).toHaveBeenCalledTimes(2);

    track.readyState = 'ended';
    track.onended();
    expect(oninterrupt).toHaveBeenLastCalledWith('ended');
    expect(handle.alive).toBe(false);

    await handle.stop();
    expect(track.onmute).toBeNull();
    expect(context.onstatechange).toBeNull();
  });
});
