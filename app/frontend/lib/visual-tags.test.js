import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { expect, test } from 'vitest';
import { iconLabel, visualTagColour, visualTagIconName, visualTagIconNames } from './visual-tags';
import { visualTagIconKeywords, visualTagIconMatches } from './visual-tag-icon-search';

test('the shared catalog and sprite reproduce every installed Phosphor icon exactly', () => {
  expect(execFileSync('node', ['scripts/generate-visual-tag-icons.mjs', '--check'], { encoding: 'utf8' })).toContain(
    'Verified'
  );
  const exports = readFileSync('node_modules/phosphor-svelte/lib/index.js', 'utf8');
  const names = [...exports.matchAll(/default as (\w+)/g)]
    .map(([, name]) => name)
    .filter((name) => name !== 'IconContext')
    .sort();
  expect(visualTagIconNames).toEqual(names);
  expect(visualTagIconNames.length).toBeGreaterThan(1500);
  const sprite = readFileSync('app/frontend/assets/visual-tag-icons.svg', 'utf8');
  expect([...sprite.matchAll(/<symbol id="([^"]+)"/g)].map(([, id]) => id)).toEqual(
    names.flatMap((name) => [`${name}-regular`, `${name}-duotone`])
  );
  expect(sprite).not.toMatch(/<(?:script|foreignObject|image|use)\b|\son\w+=|href=/i);
});

test('valid arbitrary icons survive and unknown or prototype keys use a safe fallback', () => {
  for (const icon of visualTagIconNames) expect(visualTagIconName(icon)).toBe(icon);
  for (const icon of [null, undefined, {}, '<svg>', 'Unknown', 'constructor', '__proto__', 'Yarn#duotone']) {
    expect(visualTagIconName(icon)).toBe('ChatCircle');
  }
  expect(Object.isFrozen(visualTagIconNames)).toBe(true);
});

test('labels are searchable words and colours remain bounded CSS classes', () => {
  expect(iconLabel('MagnifyingGlass')).toBe('Magnifying Glass');
  expect(iconLabel('FileSvg')).toBe('File Svg');
  expect(iconLabel('NumberCircleZero')).toBe('Number Circle Zero');
  expect(visualTagColour('rose')).toContain('text-rose-600');
  expect(visualTagColour('<style>')).toBe(visualTagColour('slate'));
  expect(visualTagColour('constructor')).toBe(visualTagColour('slate'));
  expect(visualTagColour('__proto__')).toBe(visualTagColour('slate'));
});

test('meaning search uses installed Phosphor tags, categories and labels', () => {
  expect(visualTagIconKeywords.Coins).toContain('money');
  expect(visualTagIconMatches('Coins', 'money')).toBe(true);
  expect(visualTagIconMatches('Coins', '  MONEY finance  ')).toBe(true);
  expect(visualTagIconMatches('Coins', 'money xyznotakeyword')).toBe(false);
  expect(visualTagIconMatches('MagnifyingGlass', 'magnifying glass')).toBe(true);
  expect(visualTagIconMatches('Yarn', '')).toBe(true);
  expect(visualTagIconMatches('NotAnIcon', '')).toBe(false);
  expect(Object.keys(visualTagIconKeywords).sort()).toEqual(visualTagIconNames);
});
