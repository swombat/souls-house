// The transcriber for voice mode: one WebSocket to OpenAI's realtime
// transcription, opened with a short-lived secret from the house
// (VoiceMode::TranscriptionSecret). The page's own turn detector decides when
// a turn starts and ends; this only carries the audio and the text.
//
//   begin(samples)  a turn opened; samples are its pre-roll
//   append(samples) more of the open turn, sent in ~100 ms batches
//   commit()        the turn ended; resolves to its final transcript
//   discard()       the burst was not speech; the server buffer is cleared
//   close()
//
// onDelta(text) carries the open turn's caption as it grows. Turns are matched
// to transcripts by the item id OpenAI assigns at commit, in commit order, so
// completions that arrive out of order still land on the right turn. Every
// commit we send gets exactly one acknowledgement (or one refusal); `acks`
// holds the turns in the order their commits went out and is only consumed by
// those, so a turn that has already timed out still takes its own late
// acknowledgement and can never hand its words to the next turn. When the
// socket drops, waiting turns fail and the next turn reconnects with a fresh
// secret (a locked phone, a change of network).
import { pcm16Base64 } from '$lib/voice-mode';

export const COMMIT_TIMEOUT_MS = 20_000;

export function createTranscriber({
  fetchSession,
  onDelta,
  onError,
  sampleRate = 24_000,
  flushMs = 100,
  commitTimeoutMs = COMMIT_TIMEOUT_MS,
  WebSocketImpl = globalThis.WebSocket,
} = {}) {
  let socket = null;
  let pendingSocket = null; // the socket still handshaking, so close() can cancel it
  let opening = null;
  let outbox = [];
  let open = null; // the turn being spoken
  let waiting = []; // committed turns, oldest first, until their transcript arrives
  let acks = []; // committed turns, in commit order, until OpenAI acknowledges the commit
  let batch = [];
  let batchLength = 0;
  let closed = false;
  const flushSamples = Math.round((sampleRate * flushMs) / 1000);

  function send(event) {
    if (socket && socket.readyState === 1) socket.send(JSON.stringify(event));
    else outbox.push(event);
  }

  function connect() {
    if (closed) return Promise.reject(new Error('Voice mode has ended.'));
    if (socket && socket.readyState === 1) return Promise.resolve();
    if (opening) return opening;
    opening = (async () => {
      const session = await fetchSession();
      if (closed) throw new Error('Voice mode has ended.');
      await new Promise((resolve, reject) => {
        const ws = new WebSocketImpl(session.socket_url, [
          'realtime',
          `openai-insecure-api-key.${session.client_secret}`,
        ]);
        pendingSocket = ws;
        let settled = false;
        const refuse = (message) => {
          if (settled) return;
          settled = true;
          if (pendingSocket === ws) pendingSocket = null;
          reject(new Error(message));
        };
        ws.onopen = () => {
          if (pendingSocket === ws) pendingSocket = null;
          if (closed) {
            // End was pressed during the handshake: this socket is not wanted.
            refuse('Voice mode has ended.');
            try {
              ws.close();
            } catch {
              // already closed
            }
            return;
          }
          settled = true;
          socket = ws;
          const pending = outbox;
          outbox = [];
          pending.forEach((event) => ws.send(JSON.stringify(event)));
          resolve();
        };
        ws.onerror = () => refuse('Could not connect to the transcriber.');
        ws.onclose = () => {
          refuse(closed ? 'Voice mode has ended.' : 'Could not connect to the transcriber.');
          if (socket === ws) dropped();
        };
        ws.onmessage = (message) => receive(message.data);
      });
    })()
      .catch((error) => {
        // Nothing queued for a connection that never opened may be replayed
        // onto the next one: the turns it belonged to fail with this error.
        outbox = [];
        acks = [];
        throw error;
      })
      .finally(() => {
        opening = null;
      });
    return opening;
  }

  // The connection went away: nothing in flight can complete on it.
  function dropped() {
    socket = null;
    outbox = [];
    acks = [];
    const lost = waiting;
    waiting = [];
    lost.forEach((turn) => turn.fail(new Error('The connection to the transcriber dropped.')));
    if (open) open.lost = true;
  }

  function receive(data) {
    let event;
    try {
      event = JSON.parse(data);
    } catch {
      return;
    }
    const byItem = (id) => waiting.find((turn) => turn.itemId === id);
    switch (event.type) {
      case 'input_audio_buffer.committed': {
        // The oldest commit still unacknowledged, whether or not its turn has
        // already given up waiting.
        const turn = acks.shift();
        if (turn) turn.itemId = event.item_id;
        break;
      }
      case 'conversation.item.input_audio_transcription.delta': {
        const turn = byItem(event.item_id);
        if (turn) {
          turn.text += event.delta || '';
          onDelta?.(turn.text);
        }
        break;
      }
      case 'conversation.item.input_audio_transcription.completed': {
        const turn = byItem(event.item_id);
        if (turn) turn.finish((event.transcript ?? turn.text).trim());
        break;
      }
      case 'conversation.item.input_audio_transcription.failed': {
        const turn = byItem(event.item_id);
        if (turn) turn.fail(new Error(event.error?.message || 'Transcription failed.'));
        break;
      }
      case 'error': {
        // A refused commit (an empty buffer, say) has no item: it belongs to
        // the oldest commit still unacknowledged.
        const message = event.error?.message || 'The transcriber reported an error.';
        const turn = acks.shift();
        if (turn) turn.fail(new Error(message));
        else onError?.(message);
        break;
      }
      default:
        break;
    }
  }

  function flush() {
    if (!batchLength) return;
    const samples = new Float32Array(batchLength);
    let offset = 0;
    for (const chunk of batch) {
      samples.set(chunk, offset);
      offset += chunk.length;
    }
    batch = [];
    batchLength = 0;
    send({ type: 'input_audio_buffer.append', audio: pcm16Base64(samples) });
  }

  function newTurn() {
    const turn = { text: '', itemId: null, lost: false };
    turn.done = new Promise((resolve, reject) => {
      turn.finish = (text) => {
        clearTimeout(turn.timer);
        waiting = waiting.filter((candidate) => candidate !== turn);
        resolve(text);
      };
      turn.fail = (error) => {
        clearTimeout(turn.timer);
        waiting = waiting.filter((candidate) => candidate !== turn);
        reject(error);
      };
    });
    // Nothing awaits a turn until commit; don't let an early failure go unhandled.
    turn.done.catch(() => {});
    return turn;
  }

  const transcriber = {
    connect,
    begin(samples) {
      const turn = newTurn();
      open = turn;
      batch = [];
      batchLength = 0;
      connect().catch((error) => {
        // Before commit, commit reports it; after, the waiting turn fails now.
        turn.error = error;
        if (waiting.includes(turn)) turn.fail(error);
      });
      if (samples?.length) transcriber.append(samples);
    },
    append(samples) {
      if (!open || !samples?.length) return;
      batch.push(samples);
      batchLength += samples.length;
      if (batchLength >= flushSamples) flush();
    },
    commit() {
      const turn = open;
      open = null;
      if (!turn) return Promise.resolve('');
      if (turn.error) return Promise.reject(turn.error);
      if (turn.lost) return Promise.reject(new Error('The connection to the transcriber dropped mid-sentence.'));
      flush();
      turn.timer = setTimeout(() => turn.fail(new Error('The transcript did not arrive in time.')), commitTimeoutMs);
      waiting.push(turn);
      acks.push(turn);
      send({ type: 'input_audio_buffer.commit' });
      return turn.done;
    },
    discard() {
      if (!open) return;
      open = null;
      batch = [];
      batchLength = 0;
      send({ type: 'input_audio_buffer.clear' });
    },
    close() {
      closed = true;
      const lost = waiting;
      waiting = [];
      acks = [];
      lost.forEach((turn) => turn.fail(new Error('Voice mode has ended.')));
      open = null;
      outbox = [];
      for (const ws of [socket, pendingSocket]) {
        try {
          ws?.close();
        } catch {
          // already closed
        }
      }
      socket = null;
      pendingSocket = null;
    },
    get connected() {
      return Boolean(socket && socket.readyState === 1);
    },
  };
  return transcriber;
}
