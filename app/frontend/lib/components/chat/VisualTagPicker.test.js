import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, test, vi } from 'vitest';
import VisualTagPicker from './VisualTagPicker.svelte';
import ChatSidebarItem from './ChatSidebarItem.svelte';

const { reloadProps } = vi.hoisted(() => ({ reloadProps: vi.fn() }));
vi.mock('$lib/cable', () => ({ reloadProps, subscribeToModel: vi.fn(() => vi.fn()) }));

let fetchMock;
beforeEach(() => {
  reloadProps.mockReset();
  fetchMock = vi.fn((url, request) => Promise.resolve(saved(JSON.parse(request.body).visual_tag_id)));
  globalThis.fetch = fetchMock;
});
const tagsById = {};
let clock = Date.parse('2026-11-01T18:00:00Z');
function saved(id) {
  clock += 1000;
  return { ok: true, status: 200, json: () => Promise.resolve({ visual_tag: id ? tagsById[id] : null, updated_at: new Date(clock).toISOString() }) };
}
const failed = () => ({ ok: false, status: 422, json: () => Promise.resolve({ errors: {} }) });
const sentBody = (call = fetchMock.mock.calls.at(-1)) => JSON.parse(call[1].body);

const tag = { id: 'tag-one', label: 'Research', icon: 'MagnifyingGlass', colour: 'teal' };
const other = { id: 'tag-two', label: 'Plans', icon: 'Compass', colour: 'green' };
Object.assign(tagsById, { 'tag-one': tag, 'tag-two': other });
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
  finish(saved('tag-one'));
  await waitFor(() => expect(reloadProps).toHaveBeenCalledWith(['chats', 'visual_tags']));
});

test('clicks during a save are sent one at a time, and the last one lands', async () => {
  const pending = [];
  fetchMock.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));
  render(VisualTagPicker, { ...props, tags: [tag, other] });
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Research' }));
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Plans' }));
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('button', { name: 'Change visual tag: Plans' })).toBeInTheDocument();
  pending[0](saved('tag-one'));
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  expect(sentBody()).toEqual({ visual_tag_id: 'tag-two' });
});

async function pick(name) {
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name }));
}

test('a queued save that fails falls back to the save before it, not to the stale prop', async () => {
  const pending = [];
  fetchMock.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));
  render(VisualTagPicker, { ...props, tags: [tag, other] });
  await pick('Research');
  await pick('Plans');
  pending[0](saved('tag-one'));
  await waitFor(() => expect(pending).toHaveLength(2));
  pending[1](failed());
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not change visual tag');
  expect(screen.getByRole('button', { name: 'Change visual tag: Research' })).toBeInTheDocument();
  expect(reloadProps).toHaveBeenCalledWith(['chats', 'visual_tags']);
});

test('a list snapshot read before the last save cannot put an older tag back; a newer one can', async () => {
  const pending = [];
  fetchMock.mockImplementation(() => new Promise((resolve) => pending.push(resolve)));
  const { rerender } = render(VisualTagPicker, { ...props, tags: [tag, other] });
  await pick('Research');
  await pick('Plans');
  const first = saved('tag-one');
  const researchAt = (await first.json()).updated_at;
  pending[0](first);
  await waitFor(() => expect(pending).toHaveLength(2));
  pending[1](saved('tag-two'));
  await waitFor(() => expect(reloadProps).toHaveBeenCalled());
  // The broadcast refresh that read the row between the two writes arrives late.
  await rerender({ ...props, tags: [tag, other], chat: { ...props.chat, visual_tag: tag, updated_at: researchAt } });
  expect(screen.getByRole('button', { name: 'Change visual tag: Plans' })).toBeInTheDocument();
  // Same late snapshot without a timestamp: still not authoritative over the acknowledged Plans.
  await rerender({ ...props, tags: [tag, other], chat: { ...props.chat, visual_tag: tag } });
  expect(screen.getByRole('button', { name: 'Change visual tag: Plans' })).toBeInTheDocument();
  // A later change by someone else does show.
  const later = new Date(clock + 60_000).toISOString();
  await rerender({ ...props, tags: [tag, other], chat: { ...props.chat, visual_tag: null, updated_at: later } });
  expect(screen.getByRole('button', { name: 'Change visual tag: No tag' })).toBeInTheDocument();
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
  fetchMock.mockImplementation(() => Promise.resolve(failed()));
  render(VisualTagPicker, { ...props, chat: { ...props.chat, visual_tag: tag } });
  await fireEvent.click(screen.getByRole('button'));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'No tag' }));
  expect(sentBody()).toEqual({ visual_tag_id: null });
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not change visual tag');
  expect(screen.getByRole('button', { name: 'Change visual tag: Research' })).toBeInTheDocument();
  // and asks for the real state, in case the failure hides a write that did land
  expect(reloadProps).toHaveBeenCalledWith(['chats', 'visual_tags']);
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
