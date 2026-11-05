// Up arrow in an empty composer edits the last message you posted (desktop only).
// "Yours" is what the server says: Message#editable is true for the author (and
// for a site admin on anyone's message, which controls_admin_only marks). The
// shortcut takes the newest message editable as the author, skipping other
// people's messages and residents' replies; a site admin's shortcut never
// lands on someone else's message.
export const DESKTOP_POINTER_QUERY = '(hover: hover) and (pointer: fine)';

export function lastEditableOwnMessage(messages) {
  if (!Array.isArray(messages)) return null;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i];
    if (!message || message.discarded_at || message.role !== 'user') continue;
    if (message.editable && !message.controls_admin_only) return message;
  }
  return null;
}

export function desktopPointer() {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia(DESKTOP_POINTER_QUERY).matches;
}

// Whether this keydown in the composer should open the edit drawer instead of moving the cursor.
export function wantsEditLast(event, { empty, busy }) {
  if (event.key !== 'ArrowUp') return false;
  if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey || event.isComposing) return false;
  if (!empty || busy) return false;
  return desktopPointer();
}
