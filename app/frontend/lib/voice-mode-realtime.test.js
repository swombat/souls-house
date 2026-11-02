import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { createTranscriber } from './voice-mode-realtime';

// A WebSocket the test opens, feeds and closes by hand.
class FakeSocket {
  static all = [];
  constructor(url, protocols) {
    this.url = url;
    this.protocols = protocols;
    this.readyState = 0;
    this.sent = [];
    FakeSocket.all.push(this);
  }
  send(data) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.readyState = 3;
    this.onclose?.();
  }
  open() {
    this.readyState = 1;
    this.onopen?.();
  }
  emit(event) {
    this.onmessage?.({ data: JSON.stringify(event) });
  }
  types() {
    return this.sent.map((e) => e.type);
  }
}

const session = { client_secret: 'ek_test', socket_url: 'wss://api.openai.com/v1/realtime?intent=transcription' };

function make(overrides = {}) {
  const fetchSession = vi.fn(async () => session);
  const onDelta = vi.fn();
  const t = createTranscriber({
    fetchSession,
    onDelta,
    WebSocketImpl: FakeSocket,
    sampleRate: 1000,
    flushMs: 100,
    ...overrides,
  });
  return { t, fetchSession, onDelta };
}

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  FakeSocket.all = [];
});
afterEach(() => vi.useRealTimers());

describe('createTranscriber', () => {
  test('opens the socket with the secret as a subprotocol and sends audio queued before it opened', async () => {
    const { t } = make();
    t.begin(new Float32Array(150));
    await flushPromises();
    const ws = FakeSocket.all[0];
    expect(ws.url).toBe(session.socket_url);
    expect(ws.protocols).toEqual(['realtime', 'openai-insecure-api-key.ek_test']);
    expect(ws.sent).toEqual([]);
    ws.open();
    expect(ws.types()).toEqual(['input_audio_buffer.append']);
    // 150 samples at 1 kHz as 16-bit PCM is 300 bytes, 400 base64 characters.
    expect(ws.sent[0].audio).toHaveLength(400);
  });

  test('batches appends and commits the remainder; the transcript lands by item id', async () => {
    const { t, onDelta } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    const ws = FakeSocket.all[0];
    t.begin(new Float32Array(40));
    t.append(new Float32Array(40));
    expect(ws.types()).toEqual([]);
    t.append(new Float32Array(40));
    expect(ws.types()).toEqual(['input_audio_buffer.append']);
    t.append(new Float32Array(10));
    const done = t.commit();
    expect(ws.types()).toEqual(['input_audio_buffer.append', 'input_audio_buffer.append', 'input_audio_buffer.commit']);

    ws.emit({ type: 'input_audio_buffer.committed', item_id: 'item_1' });
    ws.emit({ type: 'conversation.item.input_audio_transcription.delta', item_id: 'item_1', delta: 'Hello,' });
    ws.emit({ type: 'conversation.item.input_audio_transcription.delta', item_id: 'item_1', delta: ' there' });
    expect(onDelta).toHaveBeenLastCalledWith('Hello, there');
    ws.emit({
      type: 'conversation.item.input_audio_transcription.completed',
      item_id: 'item_1',
      transcript: ' Hello there. ',
    });
    await expect(done).resolves.toBe('Hello there.');
  });

  test('two turns in flight each get their own transcript even when completions arrive out of order', async () => {
    const { t } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    const ws = FakeSocket.all[0];
    t.begin(new Float32Array(10));
    const first = t.commit();
    t.begin(new Float32Array(10));
    const second = t.commit();
    ws.emit({ type: 'input_audio_buffer.committed', item_id: 'a' });
    ws.emit({ type: 'input_audio_buffer.committed', item_id: 'b' });
    ws.emit({ type: 'conversation.item.input_audio_transcription.completed', item_id: 'b', transcript: 'second' });
    ws.emit({ type: 'conversation.item.input_audio_transcription.completed', item_id: 'a', transcript: 'first' });
    await expect(first).resolves.toBe('first');
    await expect(second).resolves.toBe('second');
  });

  test('a discarded burst clears the server buffer', async () => {
    const { t } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    const ws = FakeSocket.all[0];
    t.begin(new Float32Array(20));
    t.discard();
    expect(ws.types()).toEqual(['input_audio_buffer.clear']);
    await expect(t.commit()).resolves.toBe('');
  });

  test('a refused commit fails its turn with the server message', async () => {
    const { t } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    const ws = FakeSocket.all[0];
    t.begin(new Float32Array(10));
    const done = t.commit();
    ws.emit({ type: 'error', error: { message: 'buffer too small' } });
    await expect(done).rejects.toThrow('buffer too small');
  });

  test('a dropped socket fails the waiting turn and the next turn reconnects with a fresh secret', async () => {
    const { t, fetchSession } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    t.begin(new Float32Array(10));
    const done = t.commit();
    FakeSocket.all[0].close();
    await expect(done).rejects.toThrow('dropped');

    t.begin(new Float32Array(10));
    await flushPromises();
    expect(fetchSession).toHaveBeenCalledTimes(2);
    expect(FakeSocket.all).toHaveLength(2);
  });

  test('a turn the socket dropped under is refused at commit rather than sent half-heard', async () => {
    const { t } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    t.begin(new Float32Array(10));
    FakeSocket.all[0].close();
    await expect(t.commit()).rejects.toThrow('mid-sentence');
  });

  test('a transcript that never arrives times out', async () => {
    vi.useFakeTimers();
    const { t } = make({ commitTimeoutMs: 1000 });
    const connecting = t.connect();
    await vi.advanceTimersByTimeAsync(0);
    FakeSocket.all[0].open();
    await connecting;
    t.begin(new Float32Array(10));
    const done = t.commit();
    const expectation = expect(done).rejects.toThrow('in time');
    await vi.advanceTimersByTimeAsync(1001);
    await expectation;
  });

  test('a failed session request fails the turn waiting on it', async () => {
    const fetchSession = vi.fn(async () => {
      throw new Error('Voice mode is not available in this account.');
    });
    const { t } = make({ fetchSession });
    t.begin(new Float32Array(10));
    const done = t.commit();
    await expect(done).rejects.toThrow('not available');
  });

  test('close fails anything waiting and closes the socket', async () => {
    const { t } = make();
    await Promise.all([t.connect(), flushPromises().then(() => FakeSocket.all[0].open())]);
    t.begin(new Float32Array(10));
    const done = t.commit();
    t.close();
    await expect(done).rejects.toThrow('ended');
    expect(FakeSocket.all[0].readyState).toBe(3);
  });

  test('a turn that timed out keeps its own late acknowledgement and never hands its words to the next turn', async () => {
    vi.useFakeTimers();
    const { t } = make({ commitTimeoutMs: 1000 });
    const connecting = t.connect();
    await vi.advanceTimersByTimeAsync(0);
    const ws = FakeSocket.all[0];
    ws.open();
    await connecting;

    t.begin(new Float32Array(10));
    const a = t.commit();
    const aRejected = expect(a).rejects.toThrow('in time');
    await vi.advanceTimersByTimeAsync(1001);
    await aRejected;

    t.begin(new Float32Array(10));
    const b = t.commit();
    // A's acknowledgement and transcript arrive late, after B was committed.
    ws.emit({ type: 'input_audio_buffer.committed', item_id: 'item_A' });
    ws.emit({
      type: 'conversation.item.input_audio_transcription.completed',
      item_id: 'item_A',
      transcript: 'words from A',
    });
    ws.emit({ type: 'input_audio_buffer.committed', item_id: 'item_B' });
    ws.emit({
      type: 'conversation.item.input_audio_transcription.completed',
      item_id: 'item_B',
      transcript: 'words from B',
    });
    await expect(b).resolves.toBe('words from B');
  });

  test('End during the handshake closes the socket when it opens and leaves nothing connected', async () => {
    const { t } = make();
    const connecting = t.connect();
    await flushPromises();
    const ws = FakeSocket.all[0];
    expect(ws.readyState).toBe(0);
    t.close();
    ws.open();
    await expect(connecting).rejects.toThrow('ended');
    expect(t.connected).toBe(false);
    expect(ws.readyState).toBe(3);
  });

  test('audio queued for a connection that never opened is not replayed onto the next one', async () => {
    const { t } = make();
    t.begin(new Float32Array(150));
    await flushPromises();
    FakeSocket.all[0].onerror();
    await flushPromises();
    await expect(t.commit()).rejects.toThrow('connect');

    t.begin(new Float32Array(150));
    await flushPromises();
    const second = FakeSocket.all[1];
    second.open();
    // Only the new turn's pre-roll, not the failed turn's audio and commit.
    expect(second.types()).toEqual(['input_audio_buffer.append']);
  });
});
