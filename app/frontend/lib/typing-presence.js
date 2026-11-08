// "Anna is typing…" / "Anna is dictating…" for the other people in a conversation
// (TypingChannel). Nothing is stored anywhere: pings go out while you type or record,
// and a name disappears a few seconds after its last ping, or at once on a stop.

export const SEND_EVERY_MS = 3000;
export const EXPIRE_AFTER_MS = 6000;

// Who is doing what, as one short line. `people` is [{ name, state }].
export function typingLabel(people) {
  const active = people.filter((p) => p.state === 'typing' || p.state === 'dictating');
  if (active.length === 0) return '';
  if (active.length > 3) return 'Several people are typing…';

  const verb = (state, plural) =>
    state === 'dictating' ? (plural ? 'are dictating' : 'is dictating') : plural ? 'are typing' : 'is typing';
  const join = (names) =>
    names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;

  const groups = ['typing', 'dictating']
    .map((state) => ({ state, names: active.filter((p) => p.state === state).map((p) => p.name) }))
    .filter((g) => g.names.length > 0);

  return `${groups.map((g) => `${join(g.names)} ${verb(g.state, g.names.length > 1)}`).join(', ')}…`;
}

// One per open conversation. `subscribe(callbacks)` returns { perform, unsubscribe };
// the real one is ActionCable's, tests pass their own.
export class TypingPresence {
  constructor({ selfUserId, subscribe, onchange = () => {}, now = () => Date.now() }) {
    this.selfUserId = selfUserId;
    this.onchange = onchange;
    this.now = now;
    this.others = new Map();
    this.sentState = 'idle';
    this.sentAt = 0;
    this.connected = false;
    this.timer = null;
    this.subscription = subscribe({
      connected: () => {
        this.connected = true;
      },
      disconnected: () => {
        this.connected = false;
        // Nobody's pings reach us while disconnected; don't leave stale names up.
        this.others.clear();
        this.sentState = 'idle';
        this.emit();
      },
      received: (data) => this.receive(data),
    });
  }

  // Your own state: 'typing' on each keystroke, 'dictating' while recording, 'idle' to stop.
  set(state) {
    if (!this.subscription) return;
    const t = this.now();
    if (state === 'idle') {
      if (this.sentState === 'idle') return;
    } else if (state === this.sentState && t - this.sentAt < SEND_EVERY_MS) {
      return;
    }
    if (!this.connected) return;
    this.sentState = state;
    this.sentAt = t;
    this.subscription.perform('typing', { state });
  }

  receive(data) {
    if (!data?.user_id || data.user_id === this.selfUserId) return;
    if (data.state === 'typing' || data.state === 'dictating') {
      this.others.set(data.user_id, { name: data.name, state: data.state, until: this.now() + EXPIRE_AFTER_MS });
    } else {
      this.others.delete(data.user_id);
    }
    this.schedule();
    this.emit();
  }

  // Drop names whose pings stopped arriving (a closed lid, a lost connection).
  sweep() {
    const t = this.now();
    let changed = false;
    for (const [id, person] of this.others) {
      if (person.until <= t) {
        this.others.delete(id);
        changed = true;
      }
    }
    if (changed) this.emit();
    this.schedule();
  }

  schedule() {
    clearTimeout(this.timer);
    this.timer = null;
    if (this.others.size === 0) return;
    const next = Math.min(...[...this.others.values()].map((p) => p.until));
    this.timer = setTimeout(() => this.sweep(), Math.max(0, next - this.now()) + 50);
  }

  label() {
    return typingLabel([...this.others.values()]);
  }

  emit() {
    this.onchange(this.label());
  }

  dispose() {
    this.set('idle');
    clearTimeout(this.timer);
    this.subscription?.unsubscribe();
    this.subscription = null;
  }
}

// The browser's version, on the shared cable connection.
export function cableTypingSubscriber(consumer, chatId) {
  return (callbacks) => {
    if (!consumer || !chatId) return null;
    return consumer.subscriptions.create({ channel: 'TypingChannel', chat_id: chatId }, callbacks);
  };
}
