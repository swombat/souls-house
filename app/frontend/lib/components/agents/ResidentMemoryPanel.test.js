import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
import ResidentMemoryPanel from './ResidentMemoryPanel.svelte';

const overview = {
  journals: { count: 17, status: 'measured' },
  node_count: 12,
  edge_count: 23,
  days: Array.from({ length: 14 }, (_, i) => ({
    date: `2026-09-${String(i + 9).padStart(2, '0')}`,
    journals: i === 13 ? 2 : 0,
    nodes: 1,
    edges: 2,
  })),
};
const entry = {
  id: 'one',
  kind: 'journals',
  title: 'A journal entry',
  path: 'daily-journals/2026-09-22.md',
  occurred_at: '2026-09-22T10:00:00.000000Z',
  timestamp_basis: 'journal heading',
  body: '<script>alert("not executable")</script>',
  body_status: 'complete',
};
const history = { items: [entry], next_cursor: 'older-cursor', archive_status: 'measured' };

beforeEach(() => {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url) => ({ ok: true, json: async () => (url === '/overview' ? overview : history) }))
  );
});
afterEach(() => vi.unstubAllGlobals());

test('shows counts and both fourteen-day charts without fetching private history for members', async () => {
  render(ResidentMemoryPanel, { overviewUrl: '/overview' });
  expect(await screen.findByText('17')).toBeInTheDocument();
  expect(screen.getAllByRole('img')).toHaveLength(2);
  expect(screen.getAllByRole('table')).toHaveLength(2);
  expect(screen.queryByRole('region', { name: 'Memory history' })).not.toBeInTheDocument();
  expect(fetch).toHaveBeenCalledTimes(1);
});

test('admin filters default on, hide deselected kinds, and pagination preserves filters', async () => {
  render(ResidentMemoryPanel, { overviewUrl: '/overview', historyUrl: '/history' });
  expect(await screen.findByText('A journal entry')).toBeInTheDocument();
  expect(screen.getAllByRole('checkbox')).toHaveLength(5);
  screen.getAllByRole('checkbox').forEach((box) => expect(box).toBeChecked());
  await fireEvent.click(screen.getByLabelText('Journals'));
  await waitFor(() => expect(fetch.mock.calls.at(-1)[0]).not.toContain('kinds=journals'));
  await screen.findByText('A journal entry');
  await fireEvent.click(screen.getByRole('button', { name: 'Older' }));
  expect(await screen.findByText('Page 2')).toBeInTheDocument();
  expect(fetch.mock.calls.at(-1)[0]).toContain('cursor=older-cursor');
  expect(fetch.mock.calls.at(-1)[0]).not.toContain('kinds=journals');
  await fireEvent.click(screen.getByRole('button', { name: 'Newer' }));
  expect(await screen.findByText('Page 1')).toBeInTheDocument();
  screen.getAllByRole('button').forEach((button) => expect(button).toHaveAttribute('type', 'button'));
});

test('journal content is rendered as text, not executable HTML', async () => {
  const { container } = render(ResidentMemoryPanel, { overviewUrl: '/overview', historyUrl: '/history' });
  expect(await screen.findByText(entry.body)).toBeInTheDocument();
  expect(container.querySelector('script')).toBeNull();
});

test('unavailable journals are unknown and do not produce an empty chart', async () => {
  fetch.mockResolvedValue({
    ok: true,
    json: async () => ({ ...overview, journals: { count: null, status: 'unavailable' } }),
  });
  render(ResidentMemoryPanel, { overviewUrl: '/overview' });
  expect(await screen.findByText(/journal counts are unknown/)).toBeInTheDocument();
  expect(screen.getAllByRole('img')).toHaveLength(1);
  expect(screen.getByText('—')).toBeInTheDocument();
});

test('all-off is sent explicitly rather than falling back to every type', async () => {
  render(ResidentMemoryPanel, { overviewUrl: '/overview', historyUrl: '/history' });
  await screen.findByText('A journal entry');
  for (const box of screen.getAllByRole('checkbox')) await fireEvent.click(box);
  await waitFor(() => expect(fetch.mock.calls.at(-1)[0]).toBe('/history?kinds='));
});

test('shows request failures with a retry instead of stale contents', async () => {
  fetch.mockImplementation(async (url) => ({ ok: url === '/overview', status: 403, json: async () => overview }));
  render(ResidentMemoryPanel, { overviewUrl: '/overview', historyUrl: '/history' });
  expect(await screen.findByRole('alert')).toHaveTextContent('Access denied.');
  expect(screen.getByRole('button', { name: 'Retry from newest' })).toBeInTheDocument();
});
