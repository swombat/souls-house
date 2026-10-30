// What an avatar picker can be handed: a file (picked, dropped, pasted) or a web
// address (pasted, typed, or an image dragged in from another tab). The server
// fetches addresses itself; these helpers only decide which of the two we have.

export const AVATAR_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
export const AVATAR_MAX_BYTES = 5 * 1024 * 1024;

export function avatarFileError(file) {
  if (!file) return 'No picture found';
  if (!AVATAR_TYPES.includes(file.type)) return 'That isn’t a PNG, JPEG, GIF or WebP picture';
  if (file.size > AVATAR_MAX_BYTES) return 'That picture is over 5 MB';
  return null;
}

// A single http(s) address, or null. Whitespace around it is forgiven; anything
// else (a sentence with a link in it, two links) is not an address.
export function webAddress(text) {
  const candidate = String(text ?? '').trim();
  if (!candidate || /\s/.test(candidate)) return null;
  try {
    const url = new URL(candidate);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null;
  } catch {
    return null;
  }
}

export function imageFileFrom(transfer) {
  const files = Array.from(transfer?.files || []);
  const direct = files.find((file) => file.type.startsWith('image/'));
  if (direct) return direct;
  // Some browsers put a pasted screenshot only in items.
  for (const item of Array.from(transfer?.items || [])) {
    if (item.kind === 'file' && item.type.startsWith('image/')) return item.getAsFile();
  }
  return files[0] || null;
}

// An image dragged from another page arrives as a link, not a file.
export function webAddressFrom(transfer) {
  if (!transfer?.getData) return null;
  const uriList = transfer.getData('text/uri-list') || '';
  const first = uriList
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith('#'));
  return webAddress(first) || webAddress(transfer.getData('text/plain'));
}

export function transferHasAvatar(transfer) {
  const types = Array.from(transfer?.types || []);
  return types.includes('Files') || types.includes('text/uri-list');
}

// Paste anywhere on the page except into a field that is meant for text.
export function isTextEntry(target) {
  if (!target) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName;
  if (tag === 'TEXTAREA') return true;
  if (tag !== 'INPUT') return false;
  return !['file', 'button', 'checkbox', 'radio', 'submit', 'color', 'range'].includes(target.type);
}
