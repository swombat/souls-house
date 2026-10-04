import { render, screen, within } from '@testing-library/svelte';
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
  expect(subscribe).toHaveBeenCalledWith('Account', 'house', ['visual_tags']);
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
