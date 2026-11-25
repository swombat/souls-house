import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { expect, test, vi } from 'vitest';
import Rooms from './rooms.svelte';

const subscribe = vi.hoisted(() => vi.fn(() => vi.fn()));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));
const props = { account: { id: 'first', name: 'First' }, can_manage: true };

test('Rooms maps account presentation and permissions without replacing its draft', async () => {
  const view = render(Rooms, props);
  expect(subscribe).toHaveBeenCalledWith('Account', 'first', [
    'room_counts',
    'main_count',
    'resident_room_id',
    'account',
    'can_manage',
  ]);
  expect(subscribe).toHaveBeenCalledWith('RoomNavigation', 'first', [
    'rooms',
    'current_room',
    'main_room',
    'main_room_name',
  ]);
  await fireEvent.input(screen.getByLabelText('New room name'), { target: { value: 'Unfinished room' } });
  await view.rerender({ ...props, account: { ...props.account, name: 'Remote' }, main_count: 3 });
  expect(screen.getByLabelText('New room name')).toHaveValue('Unfinished room');
  expect(subscribe).toHaveBeenCalledTimes(2);
  await fireEvent.submit(screen.getByLabelText('New room name').closest('form'));
  const old = router.post.mock.calls.at(-1)[2];
  await view.rerender({ ...props, account: { id: 'second', name: 'Second' } });
  expect(screen.getByLabelText('New room name')).toHaveValue('');
  await fireEvent.input(screen.getByLabelText('New room name'), { target: { value: 'Second draft' } });
  old.onSuccess();
  expect(screen.getByLabelText('New room name')).toHaveValue('Second draft');
  await view.rerender({ ...props, account: { id: 'second', name: 'Second' }, can_manage: false });
  expect(screen.queryByLabelText('New room name')).not.toBeInTheDocument();
});

test('Main can be renamed and described, but not moved or removed', async () => {
  render(Rooms, {
    ...props,
    main_count: 4,
    main_room: { id: null, name: 'General', description: 'anything without a better home' },
    rooms: [{ id: 'buildRm', name: 'Build' }],
  });
  const main = screen.getByTestId('main-room-row');
  expect(main).toHaveTextContent('General');
  expect(main).toHaveTextContent('anything without a better home');
  expect(main).toHaveTextContent('4 conversations · default');
  expect(screen.queryByLabelText('Remove General')).not.toBeInTheDocument();
  expect(screen.queryByLabelText('Move General up')).not.toBeInTheDocument();
  expect(screen.getByText(/Conversations live in General, the default room/)).toBeInTheDocument();

  await fireEvent.click(screen.getByLabelText('Edit General'));
  await fireEvent.input(screen.getByLabelText('Room name'), { target: { value: 'Everything' } });
  await fireEvent.submit(screen.getByLabelText('Room name').closest('form'));
  expect(router.patch).toHaveBeenLastCalledWith(
    '/accounts/first/main_room',
    { main_room: { name: 'Everything', description: 'anything without a better home' } },
    expect.objectContaining({ preserveScroll: true })
  );
});

test('default room for residents is marked on the row and can be changed from another active room', async () => {
  render(Rooms, {
    ...props,
    rooms: [{ id: 'buildRm', name: 'Build' }],
  });
  expect(screen.queryByRole('heading', { name: 'Default room for residents' })).not.toBeInTheDocument();
  expect(screen.getByTestId('main-room-row')).toHaveTextContent('Default for residents');
  expect(screen.queryByLabelText('Set Main as default room for residents')).not.toBeInTheDocument();

  await fireEvent.click(screen.getByLabelText('Set Build as default room for residents'));
  expect(router.patch).toHaveBeenLastCalledWith(
    '/accounts/first/resident_room',
    { room_id: 'buildRm' },
    expect.objectContaining({ preserveScroll: true })
  );
});

test('resident default can be switched back to Main from the Main row', async () => {
  render(Rooms, {
    ...props,
    resident_room_id: 'buildRm',
    rooms: [{ id: 'buildRm', name: 'Build' }],
  });
  expect(screen.getByTestId('room-row')).toHaveTextContent('Default for residents');
  await fireEvent.click(screen.getByLabelText('Set Main as default room for residents'));
  expect(router.patch).toHaveBeenLastCalledWith(
    '/accounts/first/resident_room',
    { room_id: null },
    expect.objectContaining({ preserveScroll: true })
  );
});

test('a new room is sent with what it is for, and rooms show it', async () => {
  render(Rooms, {
    ...props,
    rooms: [{ id: 'buildRm', name: 'Build', description: 'technical work, PRs and deploys' }],
  });
  expect(screen.getByTestId('room-description')).toHaveTextContent('technical work, PRs and deploys');
  expect(screen.getByTestId('add-room-row').closest('ul')).toBe(screen.getByTestId('main-room-row').closest('ul'));
  await fireEvent.input(screen.getByLabelText('New room name'), { target: { value: 'Life' } });
  await fireEvent.input(screen.getByLabelText('New room: use this room when'), { target: { value: 'home things' } });
  await fireEvent.submit(screen.getByLabelText('New room name').closest('form'));
  expect(router.post.mock.calls.at(-1)[1]).toEqual({ room: { name: 'Life', description: 'home things' } });
});

test('a description typed while the add is pending survives its success', async () => {
  render(Rooms, props);
  await fireEvent.input(screen.getByLabelText('New room name'), { target: { value: 'Build' } });
  await fireEvent.submit(screen.getByLabelText('New room name').closest('form'));
  const pending = router.post.mock.calls.at(-1)[2];
  await fireEvent.input(screen.getByLabelText('New room: use this room when'), { target: { value: 'newer text' } });
  pending.onSuccess();
  expect(screen.getByLabelText('New room: use this room when')).toHaveValue('newer text');
});

test('resident models render inline in each active room row, showing overrides, defaults, and stale problems', () => {
  const lume = {
    id: 'lumeId',
    name: 'Lume',
    colour: 'orange',
    default_label: 'Claude Opus 5.5',
    choices: [
      { model_id: 'anthropic/opus', label: 'Claude Opus 5.5' },
      { model_id: 'anthropic/fable', label: 'Claude Fable 5.1' },
    ],
  };
  const mira = {
    id: 'miraId',
    name: 'Mira',
    colour: 'violet',
    default_label: 'GPT-5.4',
    choices: [
      { model_id: 'openai/gpt-5.4', label: 'GPT-5.4' },
      { model_id: 'openai/gpt-5.4-mini', label: 'GPT-5.4 Mini' },
    ],
  };
  render(Rooms, {
    ...props,
    rooms: [{ id: 'buildRm', name: 'Build' }],
    model_residents: [lume, mira],
    room_model_defaults: [
      { room_id: 'main', agent_id: 'lumeId', model_id: 'anthropic/fable', label: 'Claude Fable 5.1', problem: null },
      {
        room_id: 'buildRm',
        agent_id: 'lumeId',
        model_id: 'anthropic/old',
        label: 'Old',
        problem: 'Old is not on Lume’s list of models for conversations',
      },
    ],
  });
  expect(screen.queryByRole('heading', { name: 'Models by room' })).not.toBeInTheDocument();
  expect(screen.getByLabelText("Lume's model in Main")).toHaveTextContent('Claude Fable 5.1');
  expect(screen.getByLabelText("Mira's model in Main")).toHaveTextContent('Default');
  expect(screen.getByLabelText("Lume's model in Build")).toHaveTextContent('Old');
  expect(screen.getByTestId('room-row')).toHaveTextContent('new conversations use the default');
  expect(screen.getAllByTestId('room-models')).toHaveLength(2);
});

test('models by room are hidden when no resident has a model list', () => {
  render(Rooms, { ...props, model_residents: [] });
  expect(screen.queryByTestId('room-models')).not.toBeInTheDocument();
});

test('archived rooms are listed apart, with Open and Unarchive, and are not resident defaults', async () => {
  render(Rooms, {
    ...props,
    rooms: [
      { id: 'live', name: 'Work' },
      { id: 'old', name: 'Application', archived: true },
    ],
    room_counts: { old: 4 },
  });
  const archived = screen.getByTestId('archived-rooms');
  expect(archived).toHaveTextContent('Application');
  expect(archived).toHaveTextContent('4 conversations');
  expect(screen.getByRole('link', { name: 'Open' })).toHaveAttribute('href', '/accounts/first/chats?room=old');
  await fireEvent.click(screen.getByLabelText('Archive Work'));
  expect(router.patch).toHaveBeenLastCalledWith('/accounts/first/rooms/live', { archived: true }, expect.anything());
  await fireEvent.click(screen.getByLabelText('Unarchive Application'));
  expect(router.patch).toHaveBeenLastCalledWith('/accounts/first/rooms/old', { archived: false }, expect.anything());
  expect(screen.queryByLabelText('Archive Application')).not.toBeInTheDocument();
});

test('a member who cannot manage rooms can still open an archived room', () => {
  render(Rooms, {
    ...props,
    can_manage: false,
    rooms: [{ id: 'old', name: 'Application', archived: true }],
  });
  expect(screen.getByRole('link', { name: 'Open' })).toHaveAttribute('href', '/accounts/first/chats?room=old');
  expect(screen.queryByLabelText('Unarchive Application')).not.toBeInTheDocument();
});
