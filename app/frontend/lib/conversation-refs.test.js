import { describe, it, expect } from 'vitest';
import { Marked } from 'marked';
import { commitRefExtension } from './commit-refs.js';
import { conversationRefExtension, looksLikeConversationId } from './conversation-refs.js';

const marked = new Marked({ extensions: [commitRefExtension, conversationRefExtension] });

function refs(markdown) {
  const found = [];
  marked.walkTokens(marked.lexer(markdown), (token) => {
    if (token.type === 'conversationRef') found.push(`${token.form}:${token.id}`);
  });
  return found;
}

describe('conversation references', () => {
  it('finds bare and backticked IDs', () => {
    expect(refs('Built in eqRAMj, reviewed in `YZxGbj`.')).toEqual(['text:eqRAMj', 'code:YZxGbj']);
    expect(refs('- **landing** posted in YNwXwe (message jKnDAg)')).toEqual(['text:YNwXwe', 'text:jKnDAg']);
    expect(refs('(eqRAMj)')).toEqual(['text:eqRAMj']);
  });

  it('never looks up ordinary words', () => {
    expect(refs('Github Monday README NASDAQ McKinsey abcdef Lume walked')).toEqual([]);
    expect(looksLikeConversationId('Github')).toBe(false);
    expect(looksLikeConversationId('README')).toBe(false);
    expect(looksLikeConversationId('McKinsey')).toBe(false);
    expect(looksLikeConversationId('eqRAMj')).toBe(true);
  });

  it('lets shape-alikes through to the server, which decides', () => {
    // "iPhone" has the shape; it stays text because no conversation answers.
    expect(refs('my iPhone')).toEqual(['text:iPhone']);
  });

  it('never touches fenced code, longer codespans, links or URLs', () => {
    expect(refs('```\nsee eqRAMj\n```')).toEqual([]);
    expect(refs('run `souls show eqRAMj` first')).toEqual([]);
    expect(refs('[eqRAMj](https://souls.house/accounts/x/chats/eqRAMj)')).toEqual([]);
    expect(refs('https://souls.house/accounts/BJZbJx/chats/eqRAMj')).toEqual([]);
    expect(refs('/chats/eqRAMj and #eqRAMj and x?id=eqRAMj and eqRAMj.rb and lume@eqRAMj')).toEqual([]);
    expect(refs('eqRAMjx xeqRAMj eqRAMj_1')).toEqual([]);
  });

  it('leaves commit shas to the commit extension', () => {
    const types = [];
    marked.walkTokens(marked.lexer('51625a7 in eqRAMj'), (token) => types.push(token.type));
    expect(types).toContain('commitRef');
    expect(types).toContain('conversationRef');
  });
});
