import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const CSS = readFileSync(resolve(__dirname, '../../entrypoints/application.css'), 'utf8');

function coarseBlock() {
  const start = CSS.indexOf('@media (pointer: coarse)');
  expect(start).toBeGreaterThan(-1);
  let depth = 0;
  for (let i = CSS.indexOf('{', start); i < CSS.length; i++) {
    if (CSS[i] === '{') depth++;
    if (CSS[i] === '}' && --depth === 0) return CSS.slice(start, i + 1);
  }
  throw new Error('unterminated @media (pointer: coarse) block');
}

// Regression: an invisible 44px overhang (::before/::after) on 32px controls with an
// 8px gap made neighbours overlap by 4px, so one button stole part of the next
// one's taps. Touch targets must take real space instead.
describe('touch targets on coarse pointers', () => {
  it('reserve real 44px space', () => {
    const block = coarseBlock();
    expect(block).toMatch(/\.touch-target\s*\{[^}]*min-width:\s*44px/);
    expect(block).toMatch(/\.touch-target\s*\{[^}]*min-height:\s*44px/);
  });

  it('never extend the hit area with an overhanging pseudo-element', () => {
    expect(CSS).not.toMatch(/\.touch-target::(after|before)/);
  });
});
