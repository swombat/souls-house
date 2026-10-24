import { render, fireEvent, screen } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import { router } from '@inertiajs/svelte';
import Voices from './voices.svelte';

// Forgetting throws away prints and reviewed samples, with no undo. A tap by
// mistake must not get through (Daniel, 2026-10-22, gjDoBe).
const voice = (id, name, extra = {}) => ({
  id,
  name,
  used_in: 3,
  remember: true,
  remembered: true,
  recordings: 3,
  samples: 8,
  confirmed_samples: 5,
  ...extra,
});
const props = {
  account: { id: 'home' },
  house_recognition: true,
  recognise_voices: true,
  can_change_setting: true,
  voices: [voice('tilke', 'Tilke'), voice('ants', 'Ants', { samples: 2, confirmed_samples: 0 })],
};

beforeEach(() => router.delete.mockClear());

test('forget all sits folded in the danger zone, not beside the switch', () => {
  render(Voices, props);
  expect(screen.getByTestId('voices-setting').textContent).not.toMatch(/Forget all/);
  const zone = screen.getByTestId('voices-danger-zone');
  expect(zone.open).toBe(false);
  expect(zone).toContainElement(screen.getByTestId('voices-forget-all'));
});

test('forget all says what goes and needs FORGET typed; cancel deletes nothing', async () => {
  render(Voices, props);
  await fireEvent.click(screen.getByTestId('voices-forget-all'));
  const dialog = await screen.findByTestId('forget-voice-dialog');
  expect(dialog.textContent).toMatch(/2 learned voice prints/);
  expect(dialog.textContent).toMatch(/10 samples/);
  expect(dialog.textContent).toMatch(/5 confirmed samples/);
  expect(dialog.textContent).toMatch(/every name given to a speaker/);

  const go = screen.getByTestId('forget-voice-confirm');
  expect(go).toBeDisabled();
  await fireEvent.click(go);
  await fireEvent.input(screen.getByTestId('forget-voice-word'), { target: { value: 'forge' } });
  expect(go).toBeDisabled();
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(router.delete).not.toHaveBeenCalled();

  await fireEvent.click(screen.getByTestId('voices-forget-all'));
  await fireEvent.input(await screen.findByTestId('forget-voice-word'), { target: { value: 'FORGET' } });
  await fireEvent.click(screen.getByTestId('forget-voice-confirm'));
  expect(router.delete).toHaveBeenCalledWith('/accounts/home/field/voices/prints');
});

test('forgetting one voice with confirmed samples also needs the word', async () => {
  render(Voices, props);
  await fireEvent.click(screen.getAllByTestId('voice-row').find((row) => row.textContent.includes('Tilke')));
  await fireEvent.click(screen.getByTestId('voice-forget'));
  expect(await screen.findByTestId('forget-voice-word')).toBeInTheDocument();
  expect(screen.getByTestId('forget-voice-confirm')).toBeDisabled();
});

test('deleting a name lists the name loss and requires confirmation before deleting', async () => {
  render(Voices, props);
  await fireEvent.click(screen.getAllByTestId('voice-row').find((row) => row.textContent.includes('Tilke')));
  await fireEvent.click(screen.getByRole('button', { name: 'Delete name', exact: true }));
  const dialog = await screen.findByTestId('forget-voice-dialog');
  expect(dialog.textContent).toMatch(/speakers named Tilke go back to 'Speaker N' everywhere/);
  expect(router.delete).not.toHaveBeenCalled();
  await fireEvent.input(screen.getByTestId('forget-voice-word'), { target: { value: 'FORGET' } });
  await fireEvent.click(screen.getByTestId('forget-voice-confirm'));
  expect(router.delete).toHaveBeenCalledWith('/accounts/home/field/voices/tilke');
});

test('a voice with nothing confirmed is one deliberate click, still not a browser confirm', async () => {
  const confirmSpy = vi.spyOn(window, 'confirm');
  render(Voices, props);
  await fireEvent.click(screen.getAllByTestId('voice-row').find((row) => row.textContent.includes('Ants')));
  await fireEvent.click(screen.getByTestId('voice-forget'));
  await screen.findByTestId('forget-voice-dialog');
  expect(screen.queryByTestId('forget-voice-word')).toBeNull();
  await fireEvent.click(screen.getByTestId('forget-voice-confirm'));
  expect(router.delete).toHaveBeenCalledWith('/accounts/home/field/voices/ants/print');
  expect(confirmSpy).not.toHaveBeenCalled();
});
