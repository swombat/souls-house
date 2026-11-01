import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import VisualTagPicker from './VisualTagPicker.svelte';
import ChatSidebarItem from './ChatSidebarItem.svelte';

const { reloadProps } = vi.hoisted(() => ({ reloadProps: vi.fn() }));
vi.mock('$lib/cable', () => ({ reloadProps, subscribeToModel: vi.fn(() => vi.fn()) }));

let fetchMock;
beforeEach(() => {
  reloadProps.mockReset();
  fetchMock = vi.fn(() => Promise.resolve({ ok: true, status: 204 }));
  globalThis.fetch = fetchMock;
});
const sentBody = (call = fetchMock.mock.calls.at(-1)) => JSON.parse(call[1].body);

const tag = { id: 'tag-one', label: 'Research', icon: 'MagnifyingGlass', colour: 'teal' };
const props = { chat: { id: 'room', title: 'A question', visual_tag: null }, accountId: 'house', tags: [tag] };

test('untagged and tagged controls have meaningful accessible labels', async () => {
  const { rerender } = render(VisualTagPicker, props);
  expect(screen.getByRole('button', { name: 'Change visual tag: No tag' })).toHaveAttribute('title', 'No tag');
  await rerender({ ...props, chat: { ...props.chat, visual_tag: tag } });
  expect(screen.getByRole('button', { name: 'Change visual tag: Research' })).toHaveClass('text-teal-700');
});

test('selecting a tag sends only its stable ID as a background JSON save, not a page visit', async () => {
  render(VisualTagPicker, props);
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Research' }));
  const [url, request] = fetchMock.mock.calls.at(-1);
  expect(url).toBe('/accounts/house/chats/room/visual_tag');
  expect(request).toMatchObject({ method: 'PATCH', headers: expect.objectContaining({ Accept: 'application/json' }) });
  expect(sentBody()).toEqual({ visual_tag_id: 'tag-one' });
});

test('the new tag shows at once, the control stays usable, and the list refreshes in the background', async () => {
  let finish;
  fetchMock.mockImplementation(() => new Promise((resolve) => (finish = resolve)));
  render(VisualTagPicker, props);
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Research' }));
  const button = screen.getByRole('button', { name: 'Change visual tag: Research' });
  expect(button).not.toBeDisabled();
  expect(reloadProps).not.toHaveBeenCalled();
  finish({ ok: true, status: 204 });
  await waitFor(() => expect(reloadProps).toHaveBeenCalledWith(['chats', 'visual_tags']));
});

test('clicks during a save are sent one at a time, and the last one lands', async () => {
  const pending = [];
  fetchMock.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));
  const other = { id: 'tag-two', label: 'Plans', icon: 'Compass', colour: 'green' };
  render(VisualTagPicker, { ...props, tags: [tag, other] });
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Research' }));
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Plans' }));
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('button', { name: 'Change visual tag: Plans' })).toBeInTheDocument();
  pending[0]({ ok: true, status: 204 });
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  expect(sentBody()).toEqual({ visual_tag_id: 'tag-two' });
});

test('selection list preserves server usage order without adding counts to tag labels', async () => {
  render(VisualTagPicker, {
    ...props,
    tags: [
      { ...tag, label: 'Zulu', conversation_count: 3 },
      { ...tag, id: 'unused', label: 'alpha', conversation_count: 0 },
    ],
  });
  await fireEvent.click(screen.getByRole('button'));
  await screen.findByRole('menuitem', { name: 'Zulu' });
  expect(screen.getAllByRole('menuitem').map((item) => item.textContent.trim())).toEqual(['No tag', 'Zulu', 'alpha']);
});

test('clears a tag; a failed save puts the server tag back and says so', async () => {
  fetchMock.mockImplementation(() => Promise.resolve({ ok: false, status: 422 }));
  render(VisualTagPicker, { ...props, chat: { ...props.chat, visual_tag: tag } });
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'No tag' }));
  expect(sentBody()).toEqual({ visual_tag_id: null });
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not change visual tag');
  expect(screen.getByRole('button', { name: 'Change visual tag: Research' })).toBeInTheDocument();
  expect(reloadProps).not.toHaveBeenCalled();
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
