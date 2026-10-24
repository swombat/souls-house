// What a collapsed integration row says without opening it: who can use the
// connection, and whether something needs doing first. Problems are spelled
// out in words, not left to colour.

const MAX_NAMES = 3;

export function connectionTitle(connection) {
  return connection.provider === 'google_workspace' ? connection.identity : connection.label;
}

export function accessSummary(connection) {
  const residents = connection.residents || [];
  if (residents.length === 0) return { text: 'No residents in this account yet', none: true };
  const enabled = residents.filter((resident) => resident.enabled);
  if (enabled.length === 0) return { text: 'No residents have access', none: true };
  if (enabled.length <= MAX_NAMES) return { text: enabled.map((resident) => resident.name).join(', '), none: false };
  return { text: `${enabled.length} of ${residents.length} residents`, none: false };
}

// A short label for a connection that cannot be used as it stands, or null.
export function attentionLabel(connection) {
  const { provider, status } = connection;
  if (status === 'reauthorizing') return provider === 'whatsapp' ? 'Pair again' : 'Reconnect needed';
  if (status === 'pairing') return provider === 'telegram' ? 'Waiting for sign-in' : 'Waiting for pairing';
  if (status === 'error') return provider === 'whatsapp' ? 'Pair again' : 'Needs attention';
  if (status === 'revoked' && connection.comms?.unpair_pending) return 'Unlinking device';
  return null;
}

// Rows that need something done start open, so the action is in reach.
export function startsOpen(connection) {
  return attentionLabel(connection) !== null;
}
