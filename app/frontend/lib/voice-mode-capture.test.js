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
