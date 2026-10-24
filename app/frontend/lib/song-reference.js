// A reference occupies a whole Markdown paragraph. Inspect the original text,
// not inline tokens: Streamdown treats bracketed expressions as citations.
export function songReference(token) {
  if (token?.type !== 'paragraph') return null;
  return /^\[\[song:([A-Za-z0-9]+)\]\][ \t]*\n?$/.exec(token.raw || '')?.[1] || null;
}

// Offers are separate from opaque Field IDs. Only these four escapes exist;
// unknown escapes and unescaped brackets leave the whole paragraph as text.
export function songOffer(token) {
  if (token?.type !== 'paragraph') return null;
  const match = /^\[\[song:([^\r\n]*)\]\][ \t]*\n?$/.exec(token.raw || '');
  if (!match) return null;
  const fields = [''];
  for (let i = 0; i < match[1].length; i++) {
    let character = match[1][i];
    if (character === '\\') {
      character = match[1][++i];
      if (!character || !'\\|[]'.includes(character)) return null;
    } else if (character === '|') {
      fields.push('');
      if (fields.length > 3) return null;
      continue;
    } else if ('[]'.includes(character)) {
      return null;
    }
    fields[fields.length - 1] += character;
  }
  // A separator distinguishes an offer from the legacy ID syntax. A URL
  // without metadata is also an offer; URL safety is exclusively server-owned.
  if (fields.length === 1 && !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(fields[0])) return null;
  const [url, title = '', artist = ''] = fields.map((field) => field.trim());
  return url ? { url, title, artist } : null;
}
