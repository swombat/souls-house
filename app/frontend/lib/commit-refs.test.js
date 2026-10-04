import { describe, it, expect } from 'vitest';
import { Marked } from 'marked';
import { commitRefExtension, looksLikeSha } from './commit-refs.js';

const marked = new Marked({ extensions: [commitRefExtension] });

function refs(markdown) {
  const found = [];
  marked.walkTokens(marked.lexer(markdown), (token) => {
    if (token.type === 'commitRef') found.push(`${token.form}:${token.sha}`);
  });
  return found;
}

describe('commit references', () => {
  it('finds bare, backticked and souls-house URL shas', () => {
    expect(refs('Merged as 51625a7 and `783ab2e`.')).toEqual(['text:51625a7', 'code:783ab2e']);
    expect(
      refs('See https://github.com/swombat/souls-house/commit/51625a7795b2b2369a1aafa009b63093dcafc7d3 now')
    ).toEqual(['url:51625a7795b2b2369a1aafa009b63093dcafc7d3']);
    expect(refs('- **fix** in 001eabe9e8cb')).toEqual(['text:001eabe9e8cb']);
  });

  it('ignores words, numbers and longer hex', () => {
    expect(refs('defaced deadbeef 1234567 abc123 a sha256 of ' + 'ab12'.repeat(16))).toEqual([]);
    expect(looksLikeSha('deadbeef')).toBe(false);
    expect(looksLikeSha('1234567')).toBe(false);
    expect(looksLikeSha('51625a7')).toBe(true);
  });

  it('never touches fenced code or longer codespans', () => {
    expect(refs('```\ngit show 51625a7\n```')).toEqual([]);
    expect(refs('run `git show 51625a7` first')).toEqual([]);
  });

  it('leaves other repositories and link text alone', () => {
    expect(refs('https://github.com/swombat/chaos/commit/51625a7795b2b2369a1aafa009b63093dcafc7d3')).toEqual([]);
    expect(refs('swombat/chaos@51625a7 and chaos#51625a7 and v1.51625a7')).toEqual([]);
    expect(refs('[51625a7](https://github.com/swombat/chaos/commit/51625a7)')).toEqual([]);
    expect(refs('[`51625a7`](https://github.com/swombat/chaos/commit/51625a7)')).toEqual([]);
    expect(refs('https://github.com/swombat/souls-house/commit/51625a7/extra')).toEqual([]);
  });
});
