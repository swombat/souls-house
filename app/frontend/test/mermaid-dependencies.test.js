import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { describe, expect, test } from 'vitest';

const rootRequire = createRequire(resolve('package.json'));
// Streamdown exports only its Svelte entry, not package.json.
const streamdownRequire = createRequire(resolve('node_modules/svelte-streamdown/package.json'));

function mermaidPackage(requireFrom) {
  const manifest = requireFrom.resolve('mermaid/package.json');
  return {
    ...JSON.parse(readFileSync(manifest, 'utf8')),
    require: createRequire(manifest),
  };
}

function expectVersionAtLeast(version, minimum) {
  const actual = version.split('.').map(Number);
  const required = minimum.split('.').map(Number);
  const difference = actual.findIndex((part, index) => part !== required[index]);
  expect(difference === -1 || actual[difference] > required[difference]).toBe(true);
}

describe('installed Mermaid dependencies', () => {
  test('keeps Streamdown on patched Mermaid 11, separate from root Mermaid 12', () => {
    const nested = mermaidPackage(streamdownRequire);
    const root = mermaidPackage(rootRequire);

    // GHSA-2v8p-3f2j-5mp7 and GHSA-rhh3-jpg6-66xh.
    expect(nested.version.split('.')[0]).toBe('11');
    expectVersionAtLeast(nested.version, '11.16.1');
    expect(root.version.split('.')[0]).toBe('12');
    expectVersionAtLeast(root.version, '12.2.0');
    expect(nested.require.resolve('mermaid')).not.toBe(root.require.resolve('mermaid'));
  });

  test.each([
    ['Streamdown', streamdownRequire],
    ['root', rootRequire],
  ])('%s Mermaid resolves a patched DOMPurify', (_name, requireFrom) => {
    const mermaid = mermaidPackage(requireFrom);
    // Resolve from the consuming Mermaid, not the top-level dependency tree.
    // DOMPurify does not export package.json; its entry lives in dist/.
    const entry = mermaid.require.resolve('dompurify');
    const sanitizer = JSON.parse(readFileSync(resolve(dirname(entry), '../package.json'), 'utf8'));

    expect(sanitizer.name).toBe('dompurify');
    // Includes GHSA-mrv2-3pqr-j5jr and GHSA-c6gr-qvv4-5v3f fixes.
    expectVersionAtLeast(sanitizer.version, '3.4.17');
  });
});
