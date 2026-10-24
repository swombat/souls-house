// Finds references to commits in chat markdown, so they can carry a status
// badge. Three forms are recognised:
//
//   51625a7                                     a bare sha word
//   `51625a7`                                   a codespan that is only a sha
//   https://github.com/<owner>/<name>/commit/<sha> a bare commit URL
//
// Anything else stays ordinary text: fenced code is never inline-lexed, link
// text is skipped, and repo@sha forms are left alone. A URL carries its
// repository, and is only ever looked up in that repository; a bare sha is
// looked up across the reader's repositories (CommitBadges on the server), so
// which repositories those are is the server's call, not this file's.

const SHA = '[0-9a-f]{7,40}';
const REPO = '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+';
const BARE = new RegExp(`^(${SHA})(?![0-9A-Za-z_])`);
const CODE = new RegExp(`^\`(${SHA})\`(?!\`)`);
const URL_RE = new RegExp(`^https://github\\.com/(${REPO})/commit/(${SHA})(?![\\w/?#.-]*\\w)`);
// A sha word must not continue another token: not after a word character,
// a path, a repo@ or #, a dot or a hyphen.
const START = new RegExp(
  `(?<![\\w/@#.\\-\`])${SHA}(?![0-9A-Za-z_])|(?<!\`)\`${SHA}\`|https://github\\.com/${REPO}/commit/`,
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
    if (match)
      return {
        type: 'commitRef',
        raw: match[0],
        sha: match[2],
        repo: match[1].toLowerCase(),
        form: 'url',
        href: match[0],
      };

    match = BARE.exec(src);
    if (match && looksLikeSha(match[1])) return { type: 'commitRef', raw: match[0], sha: match[1], form: 'text' };

    return undefined;
  },
};

// What the server is asked about: the sha alone, or repo@sha for a URL.
export function commitRefKey(token) {
  return token.repo ? `${token.repo}@${token.sha}` : token.sha;
}

// Whether a reader with these badge settings (the shared commit_badges prop)
// has any repository this reference could be measured against.
export function commitRefLookupable(token, settings) {
  const repos = [settings?.house_repo, ...(settings?.repos ?? [])].filter(Boolean).map((repo) => repo.toLowerCase());
  return token.repo ? repos.includes(token.repo) : repos.length > 0;
}

// deployed/merged/unmerged are the house repository's, measured against its
// running build and master. An account's repository is only ever measured
// against its own default branch (whatever it is called), never deployment.
export const STATUS_LABELS = {
  deployed: 'Deployed: included in the running build',
  merged: 'On master, not yet deployed',
  unmerged: 'Not on master',
  on_default: 'On the default branch',
  off_default: 'Not on the default branch',
};

// One stable array, so Streamdown is not handed a new extensions list per render.
export const commitRefExtensions = [commitRefExtension];
