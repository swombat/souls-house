import { lastEditableOwnMessage, wantsEditLast } from './edit-last-message';

function pointer(matches) {
  window.matchMedia.mockImplementation((query) => ({ matches, media: query }));
}

afterEach(() => pointer(false));

const mine = (id, extra = {}) => ({ id, role: 'user', editable: true, controls_admin_only: false, ...extra });

describe('lastEditableOwnMessage', () => {
  test('takes the newest message you can edit as its author, past residents and other people', () => {
    const messages = [
      mine('a'),
      mine('b'),
      { id: 'r', role: 'assistant', editable: false },
      { id: 'o', role: 'user', editable: false },
      { id: 'admin', role: 'user', editable: true, controls_admin_only: true },
    ];
    expect(lastEditableOwnMessage(messages)?.id).toBe('b');
  });

  test('skips a discarded message', () => {
    expect(lastEditableOwnMessage([mine('a'), mine('b', { discarded_at: '2026-11-04' })])?.id).toBe('a');
  });

  test('nothing of yours, nothing to edit', () => {
    expect(lastEditableOwnMessage([{ id: 'r', role: 'assistant' }])).toBeNull();
    expect(lastEditableOwnMessage([])).toBeNull();
    expect(lastEditableOwnMessage(undefined)).toBeNull();
  });
});

describe('wantsEditLast', () => {
  const up = (extra = {}) => ({ key: 'ArrowUp', ...extra });

  test('up arrow in an empty, idle composer with a mouse or trackpad', () => {
    pointer(true);
    expect(wantsEditLast(up(), { empty: true, busy: false })).toBe(true);
  });

  test('a draft keeps the arrow for moving the cursor', () => {
    pointer(true);
    expect(wantsEditLast(up(), { empty: false, busy: false })).toBe(false);
  });

  test('not while sending, with a modifier, mid-composition, or for another key', () => {
    pointer(true);
    expect(wantsEditLast(up(), { empty: true, busy: true })).toBe(false);
    expect(wantsEditLast(up({ shiftKey: true }), { empty: true, busy: false })).toBe(false);
    expect(wantsEditLast(up({ metaKey: true }), { empty: true, busy: false })).toBe(false);
    expect(wantsEditLast(up({ isComposing: true }), { empty: true, busy: false })).toBe(false);
    expect(wantsEditLast({ key: 'ArrowDown' }, { empty: true, busy: false })).toBe(false);
  });

  test('touch screens (no fine hover pointer) never get it', () => {
    pointer(false);
    expect(wantsEditLast(up(), { empty: true, busy: false })).toBe(false);
  });
});
