import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import ManageResidentsDialog from './ManageResidentsDialog.svelte';

const props = (extra = {}) => ({
  open: true,
  agents: [
    { id: 'mira', name: 'Mira', can_remove_from_chat: true },
    { id: 'lume', name: 'Lume', can_remove_from_chat: false },
  ],
  addableAgents: [{ id: 'claude', name: 'Claude', guest: true }],
  onsave: vi.fn(),
  ...extra,
});

test('lists seated residents ticked and others unticked, guests marked', () => {
  render(ManageResidentsDialog, props());
  expect(screen.getByRole('checkbox', { name: /Mira/ })).toBeChecked();
  expect(screen.getByRole('checkbox', { name: /Lume/ })).toBeChecked();
  expect(screen.getByRole('checkbox', { name: /Lume/ })).toBeDisabled();
  expect(screen.getByRole('checkbox', { name: /Claude/ })).not.toBeChecked();
  expect(screen.getByText('Guest')).toBeInTheDocument();
});

test('save is off until something changes, then sends the whole ticked set', async () => {
  const p = props();
  render(ManageResidentsDialog, p);
  const save = screen.getByRole('button', { name: 'Save' });
  expect(save).toBeDisabled();

  await fireEvent.click(screen.getByRole('checkbox', { name: /Mira/ }));
  await fireEvent.click(screen.getByRole('checkbox', { name: /Claude/ }));
  expect(save).not.toBeDisabled();
  await fireEvent.click(save);
  expect(p.onsave).toHaveBeenCalledWith(['lume', 'claude']);
});

test('ticking back to the seated set disables save again', async () => {
  render(ManageResidentsDialog, props());
  const mira = screen.getByRole('checkbox', { name: /Mira/ });
  await fireEvent.click(mira);
  await fireEvent.click(mira);
  expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
});
