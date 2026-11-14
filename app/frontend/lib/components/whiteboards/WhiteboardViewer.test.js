import { fireEvent, render, screen } from '@testing-library/svelte';
import WhiteboardViewer from './WhiteboardViewer.svelte';

const note = {
  name: 'Welfare × workspace',
  content: 'A long note worth reading slowly.',
  dated_at: null,
  last_edited_at: 'Nov 08 at 10:04 PM',
  editor_name: 'Lume',
};

test('Expand opens the note in a reader, and Escape or the × closes it', async () => {
  render(WhiteboardViewer, { selected: note });
  expect(screen.queryByTestId('reader-mode')).not.toBeInTheDocument();

  await fireEvent.click(screen.getByTestId('note-expand'));
  const reader = screen.getByTestId('reader-mode');
  expect(reader).toHaveAttribute('role', 'dialog');
  expect(reader).toHaveTextContent('A long note worth reading slowly.');
  expect(reader).toHaveTextContent('Last edited Nov 08 at 10:04 PM by Lume');
  expect(document.body.style.overflow).toBe('hidden');

  await fireEvent.keyDown(window, { key: 'Escape' });
  expect(screen.queryByTestId('reader-mode')).not.toBeInTheDocument();
  expect(document.body.style.overflow).toBe('');

  await fireEvent.click(screen.getByTestId('note-expand'));
  await fireEvent.click(screen.getByTestId('reader-mode-close'));
  expect(screen.queryByTestId('reader-mode')).not.toBeInTheDocument();
});

test('there is nothing to expand on an empty note or while editing', () => {
  const { unmount } = render(WhiteboardViewer, { selected: { ...note, content: '  ' } });
  expect(screen.queryByTestId('note-expand')).not.toBeInTheDocument();
  unmount();

  render(WhiteboardViewer, { selected: note, editing: true });
  expect(screen.queryByTestId('note-expand')).not.toBeInTheDocument();
});
