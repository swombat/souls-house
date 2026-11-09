// Finds conversation IDs in chat markdown (eqRAMj, YZxGbj), so a reader who
// can open that conversation sees a link titled with its current title. Two
// forms are recognised:
//
//   eqRAMj     a bare six-letter word
//   `eqRAMj`   a codespan that is only the ID
//
// A candidate is six ASCII letters with an uppercase letter after the first
// and at least one lowercase letter, so ordinary words ("Github", "Monday",
// "README") are never looked up. Shape alone is not enough ("iPhone" passes),
// so nothing becomes a link unless the server names it as a conversation the
// reader can open (ConversationTitles on the server); everything else
// renders exactly as written. Fenced code is never inline-lexed, link text is
// skipped, and IDs inside URLs, paths and longer tokens are left alone.

const ID = '[A-Za-z]{6}';
// Not continuing another token: not after a word character, a path, a query
// or fragment, a dot, a hyphen or a backtick; not followed by more of one.
const BEFORE = '(?<![\\w/@#.\\-`?=&:%+~])';
const AFTER = '(?![\\w/@]|[.\\-][\\w])';
const BARE = new RegExp(`^(${ID})${AFTER}`);
const CODE = new RegExp(`^\`(${ID})\`(?!\`)`);
const START = new RegExp(`${BEFORE}${ID}${AFTER}|(?<!\`)\`${ID}\`(?!\`)`, 'g');
// marked asks start() about src.slice(1), so the lookbehind cannot see the
// character just before a match at index 0; the tokenizer checks it again
// against the text already lexed.
const CONTINUES = /[\w/@#.\-`?=&:%+~]$/;

export function looksLikeConversationId(text) {
  return /^[A-Za-z]{6}$/.test(text) && /[A-Z]/.test(text.slice(1)) && /[a-z]/.test(text);
}

function firstStart(src) {
  START.lastIndex = 0;
  let match;
  while ((match = START.exec(src))) {
    if (looksLikeConversationId(match[0].replaceAll('`', ''))) return match.index;
  }
  return undefined;
}

export const conversationRefExtension = {
  name: 'conversationRef',
  level: 'inline',
  start(src) {
    return firstStart(src);
  },
  tokenizer(src, tokens) {
    if (this.lexer?.state?.inLink) return undefined;
    if (CONTINUES.test(tokens?.at(-1)?.raw ?? '')) return undefined;

    let match = CODE.exec(src);
    if (match && looksLikeConversationId(match[1]))
      return { type: 'conversationRef', raw: match[0], id: match[1], form: 'code' };

    match = BARE.exec(src);
    if (match && looksLikeConversationId(match[1]))
      return { type: 'conversationRef', raw: match[0], id: match[1], form: 'text' };

    return undefined;
  },
};
