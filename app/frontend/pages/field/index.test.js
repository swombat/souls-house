import { render, fireEvent, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { expect, test, vi } from 'vitest';

const subscribe = vi.hoisted(() => vi.fn(() => vi.fn()));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));
import FieldPage from './index.svelte';

test('Field watches separate list and status streams even without a panel, and switches both with the account', async () => {
  const props = { account: { id: 'one' }, items: [], field_empty: true };
  const component = render(FieldPage, { props });
  await tick();
  const liveProps = [
    'items',
    'current_item',
    'selected',
    'counts',
    'field_empty',
    'pagination',
    'recording_allowance',
    'tags',
  ];
  expect(subscribe).toHaveBeenCalledWith('FieldActivity', 'one', liveProps);
  expect(subscribe).toHaveBeenCalledWith('FieldTweetStream', 'one', ['tweet_stream']);
  expect(subscribe).toHaveBeenCalledTimes(2);
  expect(liveProps).not.toContain('search');
  const unsubscribe = subscribe.mock.results[0].value;
  await component.rerender({ ...props, account: { id: 'one' }, counts: { all: 1 } });
  await tick();
  expect(subscribe).toHaveBeenCalledTimes(2);
  expect(unsubscribe).not.toHaveBeenCalled();
  await component.rerender({ ...props, account: { id: 'two' } });
  await tick();
  expect(unsubscribe).toHaveBeenCalledOnce();
  expect(subscribe).toHaveBeenCalledWith('FieldActivity', 'two', liveProps);
  expect(subscribe).toHaveBeenLastCalledWith('FieldTweetStream', 'two', ['tweet_stream']);
  expect(subscribe.mock.results[1].value).toHaveBeenCalledOnce();
  const last = subscribe.mock.results.at(-1).value;
  component.unmount();
  expect(last).toHaveBeenCalledOnce();
});

test('live props do not clear an unsaved new note', async () => {
  const props = { account: { id: 'one' }, items: [], field_empty: true };
  const component = render(FieldPage, { props });
  await fireEvent.click(screen.getByTestId('field-new-note'));
  await fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'Not saved' } });
  await fireEvent.input(screen.getByLabelText(/^Note/), { target: { value: 'Keep these words' } });
  await component.rerender({ ...props, counts: { all: 3 }, tags: [{ name: 'live', count: 1 }] });
  expect(screen.getByLabelText('Name')).toHaveValue('Not saved');
  expect(screen.getByLabelText(/^Note/)).toHaveValue('Keep these words');
});

test('an edited note retains its original revision when live server content changes', async () => {
  const note = { kind: 'note', key: 'note-n', id: 'n', name: 'A note', content: 'Original', revision: 2 };
  const props = { account: { id: 'one' }, items: [], current_item: note, selected: note.key };
  const component = render(FieldPage, { props });
  await fireEvent.click(screen.getByRole('button', { name: 'Edit', exact: true }));
  const input = screen.getByPlaceholderText('Write your whiteboard content here...');
  await fireEvent.input(input, { target: { value: 'My draft' } });
  await component.rerender({ ...props, current_item: { ...note, revision: 3, content: 'Someone else' } });
  expect(input).toHaveValue('My draft');
  const fetch = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok: false,
    json: async () => ({ error: 'conflict', current_content: 'Someone else', current_revision: 3 }),
  });
  await fireEvent.click(screen.getByRole('button', { name: 'Save', exact: true }));
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({
    whiteboard: { content: 'My draft' },
    expected_revision: 2,
  });
  await tick();
  expect(screen.getByText('Someone else edited this whiteboard')).toBeInTheDocument();
  fetch.mockRestore();
});
