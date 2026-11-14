import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import ReaderModeHarness from './ReaderModeHarness.svelte';

test('opening moves the same child into the reader, so its unsaved state survives Expand and ×', async () => {
  render(ReaderModeHarness);
  const draft = screen.getByTestId('draft');
  await fireEvent.input(draft, { target: { value: 'half-written line' } });

  await fireEvent.click(screen.getByTestId('outside'));
  const reader = screen.getByTestId('reader-mode');
  expect(reader.parentElement).toBe(document.body);
  expect(screen.getByTestId('draft')).toBe(draft);
  expect(reader).toContainElement(draft);

  await fireEvent.click(screen.getByTestId('reader-mode-close'));
  expect(screen.queryByTestId('reader-mode')).not.toBeInTheDocument();
  expect(screen.getByTestId('draft')).toBe(draft);
  expect(draft.value).toBe('half-written line');
});

test('the page behind the reader is inert and does not scroll; closing gives it back', async () => {
  const { container } = render(ReaderModeHarness);
  const outside = screen.getByTestId('outside');
  outside.focus();
  await fireEvent.click(outside);
  await tick();

  expect(container).toHaveAttribute('inert');
  expect(screen.getByTestId('reader-mode')).not.toHaveAttribute('inert');
  expect(document.body.style.overflow).toBe('hidden');
  expect(document.activeElement).toBe(screen.getByTestId('reader-mode-close'));

  await fireEvent.keyDown(window, { key: 'Escape' });
  await tick();
  expect(container).not.toHaveAttribute('inert');
  expect(document.body.style.overflow).toBe('');
  expect(document.activeElement).toBe(outside);
});

test('an Escape already claimed inside the reader does not close it', async () => {
  render(ReaderModeHarness);
  await fireEvent.click(screen.getByTestId('outside'));
  const draft = screen.getByTestId('draft');
  draft.addEventListener('keydown', (event) => event.preventDefault());
  await fireEvent.keyDown(draft, { key: 'Escape' });
  expect(screen.getByTestId('reader-mode')).toBeInTheDocument();
});
