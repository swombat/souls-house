// Finds references to commits in this app's own repository (COMMIT_REPO) in
// chat markdown, so they can carry a status badge. Three forms are recognised:
//
//   51625a7                                             a bare sha word
//   `51625a7`                                           a codespan that is only a sha
//   https://github.com/swombat/souls-house/commit/<sha> a bare commit URL
//
// Anything else stays ordinary text: fenced code is never inline-lexed, link
// text is skipped, and other repositories' URLs and repo@sha forms are left
// alone, so they can never pick up a status from this repository.

export const COMMIT_REPO = 'swombat/souls-house';

const SHA = '[0-9a-f]{7,40}';
const REPO_PATH = COMMIT_REPO.replace('/', '\\/');
const BARE = new RegExp(`^(${SHA})(?![0-9A-Za-z_])`);
const CODE = new RegExp(`^\`(${SHA})\`(?!\`)`);
const URL_RE = new RegExp(`^https://github\\.com/${REPO_PATH}/commit/(${SHA})(?![\\w/?#.-]*\\w)`);
// A sha word must not continue another token: not after a word character,
// a path, a repo@ or #, a dot or a hyphen.
const START = new RegExp(
  `(?<![\\w/@#.\\-\`])${SHA}(?![0-9A-Za-z_])|(?<!\`)\`${SHA}\`|https://github\\.com/${REPO_PATH}/commit/`,
  'g'
);

// A real sha mixes digits and letters often enough; requiring both keeps
// words like "defaced" and plain numbers out of the lookups.
export function looksLikeSha(text) {
  return /^[0-9a-f]{7,40}$/.test(text) && /\d/.test(text) && /[a-f]/.test(text);
}

function firstStart(src) {
  START.lastIndex = 0;
  let match;
  while ((match = START.exec(src))) {
    const text = match[0].replaceAll('`', '');
    if (text.startsWith('https://') || looksLikeSha(text)) return match.index;
  }
  return undefined;
}

export const commitRefExtension = {
  name: 'commitRef',
  level: 'inline',
  start(src) {
    return firstStart(src);
  },
  tokenizer(src) {
    if (this.lexer?.state?.inLink) return undefined;

    let match = CODE.exec(src);
    if (match && looksLikeSha(match[1])) return { type: 'commitRef', raw: match[0], sha: match[1], form: 'code' };

    match = URL_RE.exec(src);
    if (match) return { type: 'commitRef', raw: match[0], sha: match[1], form: 'url', href: match[0] };

    match = BARE.exec(src);
    if (match && looksLikeSha(match[1])) return { type: 'commitRef', raw: match[0], sha: match[1], form: 'text' };

    return undefined;
  },
};

export const STATUS_LABELS = {
  deployed: 'Deployed: included in the running build',
  merged: 'On master, not yet deployed',
  unmerged: 'Not on master',
};

// One stable array, so Streamdown is not handed a new extensions list per render.
export const commitRefExtensions = [commitRefExtension];
