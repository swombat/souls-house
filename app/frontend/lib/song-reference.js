// A reference occupies a whole Markdown paragraph. Inspect the original text,
// not inline tokens: Streamdown treats bracketed expressions as citations.
export function songReference(token) {
  if (token?.type !== 'paragraph') return null;
  return /^\[\[song:([A-Za-z0-9]+)\]\][ \t]*\n?$/.exec(token.raw || '')?.[1] || null;
}
