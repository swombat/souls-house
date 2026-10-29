import { describe, it, expect } from 'vitest';
import { previewKind, readTextPreview, TEXT_PREVIEW_LIMIT } from './attachment-preview.js';

const file = (filename, content_type, extra = {}) => ({
  filename,
  content_type,
  inline_url: '/rails/active_storage/blobs/redirect/x/' + filename + '?disposition=inline',
  text_preview_url: '/attachment_previews/x/' + filename,
  ...extra,
});

describe('previewKind', () => {
  it('previews markdown by type or by extension', () => {
    expect(previewKind(file('comparison.md', 'text/markdown'))).toBe('markdown');
    expect(previewKind(file('notes.md', 'application/octet-stream'))).toBe('markdown');
    expect(previewKind(file('NOTES.MARKDOWN', 'text/plain'))).toBe('markdown');
  });

  it('previews images, audio, video and pdf', () => {
    expect(previewKind(file('a.png', 'image/png'))).toBe('image');
    expect(previewKind(file('recording.webm', 'audio/webm'))).toBe('audio');
    expect(previewKind(file('clip.mp4', 'video/mp4'))).toBe('video');
    expect(previewKind(file('paper.pdf', 'application/pdf'))).toBe('pdf');
  });

  it('previews plain text formats as text', () => {
    expect(previewKind(file('a.txt', 'text/plain'))).toBe('text');
    expect(previewKind(file('rows.csv', 'text/csv'))).toBe('text');
    expect(previewKind(file('data.json', 'application/json; charset=utf-8'))).toBe('text');
    expect(previewKind(file('out.log', 'application/octet-stream'))).toBe('text');
  });

  it('leaves office documents, archives and svg as download-only', () => {
    expect(
      previewKind(file('letter.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'))
    ).toBeNull();
    expect(previewKind(file('evidence.zip', 'application/zip'))).toBeNull();
    expect(previewKind(file('logo.svg', 'image/svg+xml'))).toBeNull();
  });

  it('needs the url its kind reads from', () => {
    expect(previewKind({ filename: 'a.md', content_type: 'text/markdown', inline_url: '/x' })).toBeNull();
    expect(previewKind({ filename: 'a.mp3', content_type: 'audio/mpeg', text_preview_url: '/x' })).toBeNull();
  });
});

describe('readTextPreview', () => {
  it('returns short files whole', async () => {
    const fake = async () => new Response('# Hello');
    expect(await readTextPreview('/x', fake)).toEqual({ text: '# Hello', truncated: false });
  });

  it('cuts files past the limit and says so', async () => {
    const big = 'a'.repeat(TEXT_PREVIEW_LIMIT + 10);
    const fake = async () => new Response(big);
    const result = await readTextPreview('/x', fake);
    expect(result.truncated).toBe(true);
    expect(result.text.length).toBe(TEXT_PREVIEW_LIMIT);
  });

  it('does not leave half a character at the cut', async () => {
    const big = 'a'.repeat(TEXT_PREVIEW_LIMIT - 1) + 'é'.repeat(4);
    const result = await readTextPreview('/x', async () => new Response(big));
    expect(result.truncated).toBe(true);
    expect(result.text.endsWith('a')).toBe(true);
    expect(result.text).not.toContain('\uFFFD');
  });

  it('passes the abort signal to fetch', async () => {
    const controller = new AbortController();
    let seen;
    await readTextPreview('/x', async (_url, opts) => ((seen = opts.signal), new Response('x')), controller.signal);
    expect(seen).toBe(controller.signal);
  });

  it('throws on a failed response', async () => {
    const fake = async () => new Response('nope', { status: 404 });
    await expect(readTextPreview('/x', fake)).rejects.toThrow('404');
  });
});
