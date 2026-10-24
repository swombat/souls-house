import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import Interface from './interface.svelte';

const { subscribe } = vi.hoisted(() => ({ subscribe: vi.fn(() => vi.fn()) }));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));

const popular = { id: 'popular', label: 'Zulu', icon: 'Heart', colour: 'rose', conversation_count: 3 };
const unused = { id: 'unused', label: 'alpha', icon: 'Heart', colour: 'rose', conversation_count: 0 };
const props = {
  account: { id: 'house', name: 'House' },
  visual_tags: [popular, unused],
  can_manage: true,
};

test('palette shows counts including zero in server usage order and explains the scope', () => {
  render(Interface, props);
  const palette = screen.getByLabelText('Visual tag palette');
  expect(
    within(palette)
      .getAllByRole('button')
      .map((button) => button.textContent.trim())
  ).toEqual(['Zulu (3)', 'alpha (0)']);
  expect(screen.getByText(/Counts include archived conversations in this account, but not deleted/)).toBeVisible();
  expect(subscribe).toHaveBeenCalledWith('Account', 'house', ['visual_tags', 'account', 'can_manage']);
});

test('palette updates counts and ordering when server props refresh', async () => {
  const { rerender } = render(Interface, props);
  await rerender({
    ...props,
    visual_tags: [{ ...unused, conversation_count: 4 }, popular],
  });
  const buttons = within(screen.getByLabelText('Visual tag palette')).getAllByRole('button');
  expect(buttons[0]).toHaveTextContent('alpha (4)');
  expect(buttons[1]).toHaveTextContent('Zulu (3)');
});

test('Interface keeps tag modal drafts across refreshes and closes them on account switch', async () => {
  const view = render(Interface, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Edit Zulu' }));
  await fireEvent.input(screen.getByLabelText('Label'), { target: { value: 'Unfinished tag' } });
  await view.rerender({
    ...props,
    account: { ...props.account, name: 'Remote' },
    visual_tags: [{ ...popular, label: 'Remote tag' }, unused],
  });
  expect(screen.getByLabelText('Label')).toHaveValue('Unfinished tag');
  expect(subscribe).toHaveBeenCalledTimes(1);
  await view.rerender({ ...props, account: { id: 'second', name: 'Second' } });
  expect(screen.queryByLabelText('Label')).not.toBeInTheDocument();
  expect(subscribe).toHaveBeenLastCalledWith('Account', 'second', ['visual_tags', 'account', 'can_manage']);
});
