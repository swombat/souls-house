import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import GoogleAuthority from './connection-google-authority.svelte';

const service = {
  key: 'google_workspace',
  authority_groups: [
    {
      key: 'gmail',
      name: 'Gmail',
      default: 'none',
      options: [
        { key: 'none', name: 'None', rank: 0 },
        { key: 'read', name: 'Read only', rank: 1 },
        { key: 'write', name: 'Read and write', rank: 2 },
      ],
    },
  ],
};
const connection = {
  id: 'synthetic-google',
  provider: 'google_workspace',
  status: 'connected',
  can_manage: true,
  effective_authority: { gmail: 'read' },
  granted_scopes: ['https://www.googleapis.com/auth/gmail.readonly'],
};

test('cancel discards only the authority edit, and live metadata refresh retains an active draft', async () => {
  const props = { account: { id: 'account' }, connection, services: [service] };
  const view = render(GoogleAuthority, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Edit access' }));
  await fireEvent.change(screen.getByLabelText('Gmail'), { target: { value: 'write' } });
  await view.rerender({ ...props, connection: { ...connection, identity: 'refreshed metadata' } });
  expect(screen.getByLabelText('Gmail')).toHaveValue('write');
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  await fireEvent.click(screen.getByRole('button', { name: 'Edit access' }));
  expect(screen.getByLabelText('Gmail')).toHaveValue('read');
});

test('read-only connection metadata does not expose authority-edit controls', () => {
  render(GoogleAuthority, {
    account: { id: 'account' },
    connection: { ...connection, can_manage: false },
    services: [service],
  });
  expect(screen.getByText('gmail.readonly')).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Edit access' })).not.toBeInTheDocument();
});
