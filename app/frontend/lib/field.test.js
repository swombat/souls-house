import { describe, expect, it } from 'vitest';
import { fieldItemLink, formatBytes, formatWhenWithTime, noteVersionsPath } from './field';

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

  it('builds note history paths', () => {
    expect(noteVersionsPath('abc', 'NoTe')).toBe('/accounts/abc/whiteboards/NoTe/versions');
    expect(noteVersionsPath('abc', 'NoTe', 'VeR')).toBe('/accounts/abc/whiteboards/NoTe/versions/VeR');
  });

  it('formats a moment with its time, and nothing for a missing one', () => {
    expect(formatWhenWithTime('2026-10-07T09:00:00Z')).toMatch(/2026/);
    expect(formatWhenWithTime(null)).toBe('');
    expect(formatWhenWithTime('not a date')).toBe('');
  });
});
