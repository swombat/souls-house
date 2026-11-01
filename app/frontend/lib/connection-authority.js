// What a connection's credential lets a resident do, in words: the
// provider's own summary where it gives one, else Google's products and
// levels, else the raw scopes.
export function authorityDescription(connection) {
  if (connection.authority_summary) return connection.authority_summary;

  const labels = {
    drive: 'Drive',
    docs: 'Docs',
    sheets: 'Sheets',
    slides: 'Slides',
    calendar: 'Calendar',
    gmail: 'Gmail',
    meet: 'Meet',
  };
  const authority = Object.entries(connection.effective_authority || {})
    .filter(([, level]) => level !== 'none')
    .map(([product, level]) => `${labels[product] || product}: ${level === 'write' ? 'read and write' : 'read only'}`);
  if (authority.length > 0) return authority.join('; ');

  const scopes = connection.granted_scopes || [];
  return scopes.length > 0 ? scopes.join(', ') : 'Google did not confirm the granted scopes';
}
