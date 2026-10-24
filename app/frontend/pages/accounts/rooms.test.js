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

test('the resident default is explained even before any room exists', () => {
  render(Rooms, { ...props, rooms: [] });
  expect(screen.getByRole('heading', { name: 'Default room for residents' })).toBeInTheDocument();
  expect(screen.getByTestId('resident-room-empty')).toHaveTextContent('Resident-started conversations go to Main.');
});

test('a new room is sent with what it is for, and rooms show it', async () => {
  render(Rooms, {
    ...props,
    rooms: [{ id: 'buildRm', name: 'Build', description: 'technical work, PRs and deploys' }],
  });
  expect(screen.getByTestId('room-description')).toHaveTextContent('technical work, PRs and deploys');
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

test('models by room show each resident’s room model, its default, and a default that stopped working', () => {
  const lume = {
    id: 'lumeId',
    name: 'Lume',
    default_label: 'Claude Opus 5.5',
    choices: [
      { model_id: 'anthropic/opus', label: 'Claude Opus 5.5' },
      { model_id: 'anthropic/fable', label: 'Claude Fable 5.1' },
    ],
  };
  render(Rooms, {
    ...props,
    rooms: [{ id: 'buildRm', name: 'Build' }],
    model_residents: [lume],
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
  expect(screen.getByRole('heading', { name: 'Models by room' })).toBeInTheDocument();
  expect(screen.getByLabelText("Lume's model in Main")).toHaveTextContent('Claude Fable 5.1');
  expect(screen.getByLabelText("Lume's model in Build")).toHaveTextContent('Old');
  expect(screen.getByTestId('room-models')).toHaveTextContent('new conversations use the default');
  expect(screen.getByTestId('room-models').querySelector('table')).toBeNull();
  expect(screen.getAllByTestId('room-models-room').map((room) => room.querySelector('h3').textContent)).toEqual([
    'Main',
    'Build',
  ]);
});

test('models by room are hidden when no resident has a model list', () => {
  render(Rooms, { ...props, model_residents: [] });
  expect(screen.queryByTestId('room-models')).not.toBeInTheDocument();
});
