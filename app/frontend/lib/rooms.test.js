import { describe, expect, it } from 'vitest';
import { ALL, MAIN, destinations, roomName, roomsPath, views, waitingIn } from './rooms';

const rooms = [
  { id: 'abc', name: 'Life' },
  { id: 'def', name: 'Dev' },
];

describe('rooms', () => {
  it('offers Main and the rooms as destinations, never All chats', () => {
    expect(destinations(rooms).map((room) => room.id)).toEqual([MAIN, 'abc', 'def']);
  });

  it('adds All chats as a view only', () => {
    expect(views(rooms).at(-1)).toEqual({ id: ALL, name: 'All chats' });
  });

  it('names the current selection, falling back to Main for an unknown room', () => {
    expect(roomName('abc', rooms)).toBe('Life');
    expect(roomName(ALL, rooms)).toBe('All chats');
    expect(roomName('gone', rooms)).toBe('Main');
  });

  it('reads waiting counts from reply attention', () => {
    expect(waitingIn('abc', { rooms: { abc: 2 } })).toBe(2);
    expect(waitingIn('def', { rooms: {} })).toBe(0);
    expect(waitingIn(MAIN, undefined)).toBe(0);
  });

  it('builds the room selection path', () => {
    expect(roomsPath('acc', 'all')).toBe('/accounts/acc/chats?room=all');
  });
});
