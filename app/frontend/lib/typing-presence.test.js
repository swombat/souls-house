import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { TypingPresence, typingLabel, SEND_EVERY_MS, EXPIRE_AFTER_MS } from './typing-presence';

describe('typingLabel', () => {
  test('names one, two and three people, and says what each is doing', () => {
    expect(typingLabel([])).toBe('');
    expect(typingLabel([{ name: 'Anna', state: 'typing' }])).toBe('Anna is typing…');
    expect(typingLabel([{ name: 'Anna', state: 'dictating' }])).toBe('Anna is dictating…');
    expect(
      typingLabel([
        { name: 'Anna', state: 'typing' },
        { name: 'Paulina', state: 'typing' },
      ])
    ).toBe('Anna and Paulina are typing…');
    expect(
      typingLabel([
        { name: 'Anna', state: 'typing' },
        { name: 'Paulina', state: 'dictating' },
      ])
    ).toBe('Anna is typing, Paulina is dictating…');
    expect(typingLabel(['A', 'B', 'C', 'D'].map((name) => ({ name, state: 'typing' })))).toBe(
      'Several people are typing…'
    );
  });
});

describe('TypingPresence', () => {
  let clock;
  let callbacks;
  let performed;
  let lines;
  let presence;

  beforeEach(() => {
    vi.useFakeTimers();
    clock = 0;
    performed = [];
    lines = [];
    presence = new TypingPresence({
      selfUserId: 'me',
      now: () => clock,
      onchange: (line) => lines.push(line),
      subscribe: (cbs) => {
        callbacks = cbs;
        return { perform: (action, data) => performed.push([action, data.state]), unsubscribe: vi.fn() };
      },
    });
    callbacks.connected();
  });

  afterEach(() => vi.useRealTimers());

  test('throttles your own pings, but always sends a stop', () => {
    presence.set('typing');
    presence.set('typing');
    clock += SEND_EVERY_MS - 1;
    presence.set('typing');
    clock += 1;
    presence.set('typing');
    presence.set('idle');
    presence.set('idle');
    expect(performed).toEqual([
      ['typing', 'typing'],
      ['typing', 'typing'],
      ['typing', 'idle'],
    ]);
  });

  test('never shows you your own typing', () => {
    callbacks.received({ user_id: 'me', name: 'Daniel', state: 'typing' });
    expect(presence.label()).toBe('');
  });

  test("shows someone else's typing, and clears it on their stop", () => {
    callbacks.received({ user_id: 'anna', name: 'Anna', state: 'typing' });
    expect(presence.label()).toBe('Anna is typing…');
    callbacks.received({ user_id: 'anna', name: 'Anna', state: 'idle' });
    expect(presence.label()).toBe('');
    expect(lines).toEqual(['Anna is typing…', '']);
  });

  test('a name whose pings stop arriving disappears on its own', () => {
    callbacks.received({ user_id: 'anna', name: 'Anna', state: 'dictating' });
    clock += EXPIRE_AFTER_MS + 100;
    vi.advanceTimersByTime(EXPIRE_AFTER_MS + 100);
    expect(presence.label()).toBe('');
  });

  test('a lost connection clears everyone, and nothing is sent while disconnected', () => {
    callbacks.received({ user_id: 'anna', name: 'Anna', state: 'typing' });
    callbacks.disconnected();
    expect(presence.label()).toBe('');
    presence.set('typing');
    expect(performed).toEqual([]);
  });

  test('closing the conversation mid-sentence sends a stop', () => {
    presence.set('typing');
    presence.dispose();
    expect(performed.at(-1)).toEqual(['typing', 'idle']);
  });
});
