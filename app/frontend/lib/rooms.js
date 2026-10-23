import { router } from '@inertiajs/svelte';

// Rooms are where conversations live. Main is "no room"; All chats is a view
// across every room, never a place a conversation can be moved to. An account
// can rename Main; pass its name (the shared main_room_name prop).
export const MAIN = 'main';
export const ALL = 'all';

export function destinations(rooms = [], mainName = 'Main') {
  return [{ id: MAIN, name: mainName || 'Main' }, ...rooms.map((room) => ({ id: room.id, name: room.name }))];
}

export function views(rooms = [], mainName = 'Main') {
  return [...destinations(rooms, mainName), { id: ALL, name: 'All chats' }];
}

export function roomName(key, rooms = [], mainName = 'Main') {
  if (key === ALL) return 'All chats';
  return rooms.find((room) => room.id === key)?.name ?? (mainName || 'Main');
}

// Conversations waiting on you in a room (the reply-attention stream).
export function waitingIn(key, attention) {
  return attention?.rooms?.[key] || 0;
}

// Residents working in a room, newest start first (RoomActivity). The first
// one's colour is the spinner's.
export function workingIn(key, activity) {
  if (key === ALL) return activity?.all || [];
  return activity?.rooms?.[key] || [];
}

export function roomsPath(accountId, key) {
  return `/accounts/${accountId}/chats?room=${encodeURIComponent(key)}`;
}

export function visitRoom(accountId, key) {
  router.visit(roomsPath(accountId, key));
}
