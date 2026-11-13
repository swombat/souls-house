export function initialsFor(name) {
  if (!name) return '?';
  return name
    .split(' ')
    .map((part) => part.charAt(0))
    .slice(0, 2)
    .join('')
    .toUpperCase();
}

export function shortDate(dateString) {
  if (!dateString) return '';

  const date = new Date(dateString);
  if (isNaN(date.getTime())) return '';

  return date.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
  });
}

// The hover line for the sidebar's waiting-commitment mark: who comes back,
// and when, in the viewer's own clock. The commitment's text stays on the
// resident's page; the list only says that something will wake here.
// A conversation stuck at the resident handoff limit (Daniel, 11 Nov, jaMvBj):
// its hand takes the commitment clock's place (yellow since 13 Nov, jgDWoJ).
export function handoffStuckLabel(stuck) {
  return stuck ? 'Stuck: residents reached the handoff limit here. Post a message and they can carry on.' : '';
}

// A resident whose last run in this conversation ended in an error (Daniel,
// 13 Nov, jgDWoJ): a red circled exclamation mark, which wins over the hand
// and the clock. names: the residents whose latest run here failed.
export function runErrorLabel(names) {
  if (!names?.length) return '';
  const who = names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
  const runs = names.length === 1 ? 'last run here' : 'last runs here';
  return `${who}'s ${runs} ended in an error.`;
}

export function commitmentMarkLabel(commitment, locale = undefined) {
  if (!commitment?.due_at) return '';

  const date = new Date(commitment.due_at);
  if (isNaN(date.getTime())) return '';

  const when = date.toLocaleString(locale, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
  const who = commitment.resident_name || 'A resident';
  const more = commitment.count > 1 ? ` (${commitment.count} waiting)` : '';
  return `${who} will come back here ${when}${more}`;
}
