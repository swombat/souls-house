import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { expect, test, vi } from 'vitest';
import Users from './users.svelte';

const subscribe = vi.hoisted(() => vi.fn(() => vi.fn()));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));

const activeMember = {
  id: 1,
  user_id: 1,
  display_name: 'Alice Owner',
  role: 'owner',
  confirmed_at: '2026-01-01T00:00:00Z',
  invitation_pending: false,
  can_remove: false,
  user: { email_address: 'alice@example.com', full_name: 'Alice Owner' },
};

const pendingInvitation = {
  id: 2,
  user_id: 2,
  display_name: 'bob@example.com',
  role: 'member',
  invited_at: '2026-01-02T00:00:00Z',
  invitation_pending: true,
  can_remove: true,
  invited_by: { full_name: 'Alice Owner' },
  user: { email_address: 'bob@example.com', full_name: 'Bob' },
};

const props = {
  account: { id: 'first', name: 'First', personal: false, created_at: '2026-01-01' },
  members: [activeMember, pendingInvitation],
  can_manage: true,
  can_invite_owner: true,
  current_user_id: 1,
};

test('Users subscribes to account member props and renders active members and pending invitations', async () => {
  const view = render(Users, props);
  expect(subscribe).toHaveBeenCalledWith('Account', 'first', ['account', 'members', 'can_manage', 'can_invite_owner']);
  expect(screen.getByText('Team Members (1)')).toBeInTheDocument();
  expect(screen.getByText('Pending Invitations (1)')).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Invite Member' })).toBeInTheDocument();

  await view.rerender({ ...props, can_manage: false });
  expect(screen.queryByRole('button', { name: 'Invite Member' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Resend' })).not.toBeInTheDocument();

  const cleanup = subscribe.mock.results[0].value;
  view.unmount();
  expect(cleanup).toHaveBeenCalledOnce();
});

test('invitation draft survives same-account updates and closes deliberately on account switch', async () => {
  const view = render(Users, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Invite Member' }));
  await fireEvent.input(screen.getByLabelText('Email Address'), { target: { value: 'unfinished@example.com' } });
  await view.rerender({ ...props, account: { ...props.account, name: 'Renamed remotely' } });
  expect(screen.getByLabelText('Email Address')).toHaveValue('unfinished@example.com');
  await view.rerender({ ...props, account: { ...props.account, id: 'second', name: 'Second' } });
  expect(screen.queryByLabelText('Email Address')).not.toBeInTheDocument();
});

test('personal accounts show a conversion prompt instead of team member tables', async () => {
  render(Users, {
    ...props,
    account: { id: 'personal', name: 'Personal', personal: true, created_at: '2026-01-01' },
    members: [],
  });
  expect(screen.getByText('Personal account')).toBeInTheDocument();
  expect(screen.queryByText(/Team Members/)).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Convert to team account' }));
  expect(router.visit).toHaveBeenCalledWith('/accounts/personal/edit?convert=true');
});
