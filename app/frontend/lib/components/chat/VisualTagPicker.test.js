import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { expect, test } from 'vitest';
import VisualTagPicker from './VisualTagPicker.svelte';
import ChatSidebarItem from './ChatSidebarItem.svelte';

const tag = { id: 'tag-one', label: 'Research', icon: 'MagnifyingGlass', colour: 'teal' };
const props = { chat: { id: 'room', title: 'A question', visual_tag: null }, accountId: 'house', tags: [tag] };

test('untagged and tagged controls have meaningful accessible labels', async () => {
  const { rerender } = render(VisualTagPicker, props);
  expect(screen.getByRole('button', { name: 'Change visual tag: No tag' })).toHaveAttribute('title', 'No tag');
  await rerender({ ...props, chat: { ...props.chat, visual_tag: tag } });
  expect(screen.getByRole('button', { name: 'Change visual tag: Research' })).toHaveClass('text-teal-700');
});

test('selecting a tag sends only its stable ID, not a title update', async () => {
  render(VisualTagPicker, props);
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Research' }));
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/house/chats/room/visual_tag',
    { visual_tag_id: 'tag-one' },
    expect.objectContaining({ preserveScroll: true, preserveState: true })
  );
});

test('clears a tag and reports failed saves', async () => {
  render(VisualTagPicker, { ...props, chat: { ...props.chat, visual_tag: tag } });
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'No tag' }));
  expect(router.patch.mock.calls.at(-1)[1]).toEqual({ visual_tag_id: null });
  router.patch.mock.calls.at(-1)[2].onError();
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not change visual tag');
});

test('the picker is outside the navigation link, and archived threads remain editable', () => {
  render(ChatSidebarItem, {
    chat: { ...props.chat, archived: true },
    accountId: 'house',
    visualTags: [tag],
  });
  const picker = screen.getByRole('button', { name: 'Change visual tag: No tag' });
  expect(picker.closest('a')).toBeNull();
  expect(picker).not.toBeDisabled();
  expect(screen.getByRole('link')).toHaveAttribute('href', '/accounts/house/chats/room');
});

test('deleted conversations do not advertise an available mutation', () => {
  render(VisualTagPicker, { ...props, chat: { ...props.chat, discarded: true } });
  expect(screen.getByRole('button')).toBeDisabled();
});
