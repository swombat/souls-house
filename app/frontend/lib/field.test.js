import { describe, expect, it } from 'vitest';
import { fieldItemLink, formatBytes } from './field';

describe('field helpers', () => {
  it('builds a stable item link', () => {
    expect(fieldItemLink('abc', 'file-XyZ', 'https://house.example')).toBe(
      'https://house.example/accounts/abc/field?item=file-XyZ'
    );
  });

  it('formats sizes', () => {
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(2048)).toBe('2 KB');
    expect(formatBytes(5 * 1024 * 1024)).toBe('5.0 MB');
    expect(formatBytes(null)).toBe('');
  });
});
