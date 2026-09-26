import { describe, expect, test } from 'vitest';
import { addUploadFiles, formatFileSize, removeUploadFile, validateUploadFile } from './file-upload-rules';

const file = (name, type, size = 10) => ({ name, type, size });

describe('file upload rules', () => {
  test('accepts arbitrary formats, unknown MIME types, and extensionless files', () => {
    for (const [name, type] of [
      ['data.json', 'application/json'],
      ['archive.zip', 'application/zip'],
      ['program.exe', 'application/x-msdownload'],
      ['custom.unrecognized', 'application/octet-stream'],
      ['README', ''],
    ]) {
      expect(validateUploadFile(file(name, type), { maxSize: 100 })).toBeNull();
    }
  });

  test('retains the size limit for every format', () => {
    expect(validateUploadFile(file('data.json', '', 101), { maxSize: 100 })).toMatch(/File too large/);
    expect(validateUploadFile(file('data.json', '', 100), { maxSize: 100 })).toBeNull();
  });

  test('returns the original file list when a batch exceeds limits or contains invalid files', () => {
    const existing = [file('one.png', 'image/png')];
    const options = { maxFiles: 2, maxSize: 100 };

    expect(addUploadFiles(existing, [file('two.png', 'image/png'), file('three.png', 'image/png')], options)).toEqual({
      files: existing,
      error: 'Maximum 2 files allowed.',
    });
    expect(addUploadFiles(existing, [file('two.zip', 'application/zip', 101)], options).files).toBe(existing);
  });

  test('adds and removes valid files without mutating the original list', () => {
    const existing = [file('one.png', 'image/png')];
    const nextFile = file('two.png', 'image/png');
    const result = addUploadFiles(existing, [nextFile], {
      maxFiles: 2,
      maxSize: 100,
    });

    expect(result.files).toEqual([existing[0], nextFile]);
    expect(existing).toHaveLength(1);
    expect(removeUploadFile(result.files, 0)).toEqual([nextFile]);
  });

  test('formats sizes for user-facing attachment labels', () => {
    expect(formatFileSize(512)).toBe('512 B');
    expect(formatFileSize(1536)).toBe('1.5 KB');
    expect(formatFileSize(2 * 1024 * 1024)).toBe('2.0 MB');
  });
});
