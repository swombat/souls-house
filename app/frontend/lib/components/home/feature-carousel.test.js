import { describe, expect, test } from 'vitest';
import { alternatingClipFeatures } from './feature-carousel.js';

const clip = (title) => ({ title, media: { kind: 'video', src: `/${title}.mp4` } });
const still = (title) => ({ title, media: { kind: 'image', src: `/${title}.png` } });

describe('alternatingClipFeatures', () => {
  test('alternates relational and technical, keeping only features with a clip', () => {
    const out = alternatingClipFeatures([clip('a'), still('x'), clip('b'), clip('c')], [clip('1'), clip('2')]);
    expect(out.map((f) => f.title)).toEqual(['a', '1', 'b', '2', 'c']);
    expect(out.map((f) => f.side)).toEqual(['A life', 'A working house', 'A life', 'A working house', 'A life']);
  });

  test('the real feature lists give a non-empty carousel', () => {
    expect(alternatingClipFeatures().length).toBeGreaterThan(1);
  });
});
