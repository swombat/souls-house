import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import AssistantMessageSection from './assistant-message-section.svelte';

vi.mock('$lib/components/chat/rich-ui/table.svelte', async () => ({
  default: (await import('./test-fixtures/failing-rich-table.svelte')).default,
}));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

it('keeps caption and an explicit text fallback available when a rich component throws', async () => {
  const error = vi.spyOn(console, 'error').mockImplementation(() => {});
  const fallback = 'Table: 1 rows; columns: Value.\nValue: 42.';
  const value = {
    version: 1,
    root: 'main',
    fallback,
    elements: { main: { type: 'Table', props: { columns: ['Value'], rows: [[42]] } } },
  };
  render(AssistantMessageSection, {
    message: {
      id: 'synthetic-message',
      content: `Authored caption.\n\n${fallback}`,
      rich_ui: value,
      created_at: '2026-11-07T12:00:00Z',
    },
  });
  // json-render catches leaf component errors in its own boundary.
  expect(error).toHaveBeenCalledWith(
    expect.stringContaining('Rendering error'),
    expect.objectContaining({ message: 'Synthetic rich component failure' })
  );
  expect(screen.queryByRole('table')).toBeNull();
  expect(screen.getByText('Authored caption.')).toBeTruthy();
  const disclosure = screen.getByTestId('rich-ui-fallback');
  expect(disclosure.open).toBe(false);
  expect(disclosure.textContent).toContain(fallback);
  disclosure.open = true;
  expect(disclosure.querySelector('p')).toBeVisible();
});

it("says which of a resident's named keys posted a message, and nothing for the container key", () => {
  const base = { content: 'Hello', created_at: '2026-11-13T01:00:00Z', author_type: 'agent' };
  render(AssistantMessageSection, { message: { ...base, id: 'named', api_key_label: 'Desktop' } });
  expect(screen.getByTestId('answer-key').textContent).toBe('via Desktop');
  cleanup();
  render(AssistantMessageSection, { message: { ...base, id: 'container', api_key_label: null } });
  expect(screen.queryByTestId('answer-key')).toBeNull();
});
