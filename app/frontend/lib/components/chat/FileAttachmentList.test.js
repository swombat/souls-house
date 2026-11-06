import { render, cleanup } from '@testing-library/svelte';
import { afterEach, expect, test } from 'vitest';
import FileAttachmentList from './FileAttachmentList.svelte';

afterEach(cleanup);

const file = (name) => ({ id: name, filename: name, content_type: 'video/mp4', byte_size: 1000, url: `/rails/${name}` });

test('shows Download all for two or more files', () => {
  const { getByTestId } = render(FileAttachmentList, { files: [file('a.mp4'), file('b.mp4'), file('c.mp4')] });
  expect(getByTestId('download-all-files').textContent.trim()).toBe('Download all (3)');
});

test('no Download all for a single file', () => {
  const { queryByTestId } = render(FileAttachmentList, { files: [file('a.mp4')] });
  expect(queryByTestId('download-all-files')).toBeNull();
});
