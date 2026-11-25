import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, test, beforeEach, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import Practices from './practices.svelte';

const { update } = vi.hoisted(() => ({ update: vi.fn() }));
vi.mock('$lib/use-sync', () => ({ createDynamicSync: () => update }));

const account = { id: 'home', name: 'Home' };
const path = '/accounts/home/practices';
const practices = [
  {
    id: 'a',
    text: 'Finished threads get the done tag.',
    position: 1,
    updated_by: { kind: 'resident', id: 'r', name: 'Lume' },
  },
  { id: 'b', text: 'Book afternoons.', position: 2, updated_by: { kind: 'person', name: 'Daniel' } },
];
const props = { account, path, practices, used: 50, limits: { max_length: 250, max_lines: 25, max_total: 3000 } };

beforeEach(() => {
  router.post.mockClear?.();
  router.patch.mockClear?.();
});

test('lists the lines in order with their last editor, the usage, and the guests note', () => {
  render(Practices, props);
  const lines = screen.getAllByTestId('practice-line');
  expect(lines[0]).toHaveTextContent('Finished threads get the done tag.');
  expect(lines[0]).toHaveTextContent('Last changed by Lume (resident)');
  expect(lines[1]).toHaveTextContent('Last changed by Daniel');
  expect(screen.getByTestId('practices-usage')).toHaveTextContent('50 of 3,000 characters used');
  expect(screen.getByTestId('practices-guests-note')).toHaveTextContent('Guests see these practices too.');
  expect(update).toHaveBeenLastCalledWith({ 'PracticeActivity:home': ['practices', 'used'] });
});

test('adds a line as one line', async () => {
  render(Practices, props);
  const input = screen.getByRole('textbox', { name: 'New practice' });
  await fireEvent.input(input, { target: { value: '  Mark   finished\tthreads done ' } });
  await fireEvent.submit(input.closest('form'));
  expect(router.post).toHaveBeenLastCalledWith(path, { text: 'Mark finished threads done' }, expect.any(Object));
});

test('moves a line down by asking for the next position, and the last line cannot move down', async () => {
  render(Practices, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Move "Finished threads get the done tag." down' }));
  expect(router.patch).toHaveBeenLastCalledWith(`${path}/a`, { position: 2 }, expect.any(Object));
  expect(screen.getByRole('button', { name: 'Move "Book afternoons." down' })).toBeDisabled();
});

test('a full account cannot add more', () => {
  const many = Array.from({ length: 25 }, (_, i) => ({
    id: `p${i}`,
    text: `Line ${i}`,
    position: i + 1,
    updated_by: null,
  }));
  render(Practices, { ...props, practices: many });
  expect(screen.getByRole('textbox', { name: 'New practice' })).toBeDisabled();
});
