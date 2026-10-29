// Which attachments can be previewed in place in a conversation, and how (Daniel,
// jBVqwj, 29 Oct 2026: "anything that has an easy preview"). Word and other
// office formats stay download-only: there is no easy, faithful browser preview.

const MARKDOWN_EXTENSIONS = ['md', 'markdown', 'mdown', 'mkd'];
const TEXT_EXTENSIONS = [
  'txt',
  'text',
  'log',
  'csv',
  'tsv',
  'json',
  'jsonl',
  'ndjson',
  'yml',
  'yaml',
  'toml',
  'xml',
  'ini',
  'conf',
  'rb',
  'py',
  'js',
  'ts',
  'rs',
  'go',
  'sh',
  'sql',
  'html',
  'css',
  'srt',
  'vtt',
];
const TEXT_CONTENT_TYPES = [
  'application/json',
  'application/x-ndjson',
  'application/xml',
  'application/x-yaml',
  'application/yaml',
  'application/toml',
  'application/sql',
  'application/x-sh',
  'application/javascript',
];

// Text previews read the file into the page; past this many bytes they are cut.
export const TEXT_PREVIEW_LIMIT = 1024 * 1024;

function extension(filename) {
  const name = (filename || '').toLowerCase();
  const dot = name.lastIndexOf('.');
  return dot === -1 ? '' : name.slice(dot + 1);
}

function kindOf(file) {
  const type = (file.content_type || '').toLowerCase().split(';')[0].trim();
  const ext = extension(file.filename);

  if (type === 'text/markdown' || type === 'text/x-markdown' || MARKDOWN_EXTENSIONS.includes(ext)) return 'markdown';
  if (type.startsWith('image/') && type !== 'image/svg+xml') return 'image';
  if (type.startsWith('audio/')) return 'audio';
  if (type.startsWith('video/')) return 'video';
  if (type === 'application/pdf' || ext === 'pdf') return 'pdf';
  if (type.startsWith('text/') || TEXT_CONTENT_TYPES.includes(type) || TEXT_EXTENSIONS.includes(ext)) return 'text';

  return null;
}

// Text kinds are read by the page from text_preview_url (same origin, never
// cached); the rest play from inline_url. No url, no preview.
export function previewKind(file) {
  if (!file) return null;
  const kind = kindOf(file);
  if (!kind) return null;
  const isText = kind === 'markdown' || kind === 'text';
  return (isText ? file.text_preview_url : file.inline_url) ? kind : null;
}

// Reads a text attachment for preview, stopping at TEXT_PREVIEW_LIMIT bytes.
// A cut can land inside a multi-byte character; drop the replacement mark
// the decoder leaves there.
function decodeCut(bytes) {
  return new TextDecoder().decode(bytes).replace(/\uFFFD+$/, '');
}

export async function readTextPreview(url, fetchImpl = fetch, signal = undefined) {
  const response = await fetchImpl(url, { credentials: 'same-origin', signal });
  if (!response.ok) throw new Error(`Could not load the file (${response.status}).`);

  const reader = response.body?.getReader?.();
  if (!reader) {
    const text = await response.text();
    const bytes = new TextEncoder().encode(text);
    if (bytes.length <= TEXT_PREVIEW_LIMIT) return { text, truncated: false };
    return { text: decodeCut(bytes.slice(0, TEXT_PREVIEW_LIMIT)), truncated: true };
  }

  const chunks = [];
  let received = 0;
  let truncated = false;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    const room = TEXT_PREVIEW_LIMIT - received;
    if (value.length > room) {
      chunks.push(value.slice(0, room));
      received += room;
      truncated = true;
      await reader.cancel();
      break;
    }
    chunks.push(value);
    received += value.length;
  }
  const all = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.length;
  }
  return { text: truncated ? decodeCut(all) : new TextDecoder().decode(all), truncated };
}
