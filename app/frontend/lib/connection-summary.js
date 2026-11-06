// What a collapsed integration row says without opening it: who can use the
// connection, and whether something needs doing first. Problems are spelled
// out in words, not left to colour.

const MAX_NAMES = 3;

// The row's title names the account, not the service: an icon alone does not
// say which service it is, so the service name goes underneath (serviceLine).
// When the label is only the service's own name (Telegram, WhatsApp), the
// identity the service reported is the account. A Telegram identity reads
// "Name @handle"; the handle is the account.
export function connectionTitle(connection) {
  const identity = (connection.identity || '').trim();
  if (connection.provider === 'google_workspace' && identity) return identity;

  const label = (connection.label || '').trim();
  const labelIsService = !label || sameName(label, connection.provider_name);
  if (labelIsService && identity) {
    if (connection.provider === 'telegram') {
      const handle = identity.match(/(^|\s)(@\w+)\s*$/);
      if (handle) return handle[2];
    }
    return identity;
  }
  return label || connection.provider_name || connection.provider;
}

// The service in small letters under the title, or null when the title
// already is exactly the service's name.
export function serviceLine(connection) {
  const name = (connection.provider_name || '').trim();
  if (!name || sameName(name, connectionTitle(connection))) return null;
  return name;
}

function sameName(a, b) {
  return Boolean(a && b) && a.trim().toLowerCase() === b.trim().toLowerCase();
}

// A guest's row counts once its home has approved it (effective); a request
// still waiting is not access.
export function residentHasAccess(resident) {
  return resident.guest ? Boolean(resident.effective) : Boolean(resident.enabled);
}

export function accessSummary(connection) {
  const residents = connection.residents || [];
  if (residents.length === 0) return { text: 'No residents in this account yet', none: true };
  const enabled = residents.filter(residentHasAccess);
  // Connected but nobody can use it yet: the card shows this in red (YgDZGe).
  if (enabled.length === 0) return { text: 'No residents have access', none: true, unshared: true };
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
