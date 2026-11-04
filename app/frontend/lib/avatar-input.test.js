import { describe, expect, it } from 'vitest';
import {
  avatarFileError,
  imageFileFrom,
  isTextEntry,
  transferHasAvatar,
  webAddress,
  webAddressFrom,
} from './avatar-input';

const file = (type, size = 10) => ({ type, size, name: 'x' });

describe('avatar input', () => {
  it('accepts only the four picture types under 5 MB', () => {
    expect(avatarFileError(file('image/png'))).toBeNull();
    expect(avatarFileError(file('image/svg+xml'))).toMatch(/PNG, JPEG/);
    expect(avatarFileError(file('image/jpeg', 6 * 1024 * 1024))).toMatch(/5 MB/);
    expect(avatarFileError(null)).toMatch(/No picture/);
  });

  it('reads a single http(s) address and nothing else', () => {
    expect(webAddress('  https://example.com/me.png \n')).toBe('https://example.com/me.png');
    expect(webAddress('http://example.com/a.jpg')).toBe('http://example.com/a.jpg');
    expect(webAddress('look at https://example.com/a.jpg')).toBeNull();
    expect(webAddress('file:///etc/passwd')).toBeNull();
    expect(webAddress('javascript:alert(1)')).toBeNull();
    expect(webAddress('')).toBeNull();
  });

  it('finds a pasted screenshot in items when files is empty', () => {
    const shot = file('image/png');
    const transfer = { files: [], items: [{ kind: 'file', type: 'image/png', getAsFile: () => shot }] };
    expect(imageFileFrom(transfer)).toBe(shot);
  });

  it('takes the first link of a uri-list from an image dragged out of another tab', () => {
    const data = { 'text/uri-list': '# comment\r\nhttps://cdn.example.com/p.webp\r\nhttps://other', 'text/plain': '' };
    expect(webAddressFrom({ getData: (t) => data[t] || '' })).toBe('https://cdn.example.com/p.webp');
    expect(transferHasAvatar({ types: ['text/uri-list'] })).toBe(true);
    expect(transferHasAvatar({ types: ['text/plain'] })).toBe(false);
  });

  it('leaves pastes into text fields alone', () => {
    expect(isTextEntry({ tagName: 'INPUT', type: 'text' })).toBe(true);
    expect(isTextEntry({ tagName: 'TEXTAREA' })).toBe(true);
    expect(isTextEntry({ tagName: 'INPUT', type: 'file' })).toBe(false);
    expect(isTextEntry({ tagName: 'DIV' })).toBe(false);
  });
});
