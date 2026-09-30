import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import ResidentTurns from './resident-turns.svelte';

test('pauses admissions without pretending existing turns stop', async () => {
  render(ResidentTurns, {
    enabled: true,
    limit: 50,
    counts: { queued: 4, running: 10, unknown: 1 },
    turns: [],
  });
  const input = screen.getByLabelText('Turn limit (0 pauses admission)');
  await fireEvent.input(input, { target: { value: '0' } });
  await fireEvent.submit(input.closest('form'));
  expect(router.patch).toHaveBeenCalledWith('/admin/resident_turns/capacity', { limit: 0 });
  expect(screen.getByText(/never kills an existing turn/)).toBeVisible();
});

test('cancels a turn through its own admin resource', async () => {
  render(ResidentTurns, {
    enabled: true,
    limit: 50,
    counts: { running: 1 },
    turns: [{ id: 42, resident: 'Synthetic', kind: 'wake', state: 'running', queued_at: '2026-09-30T12:00:00Z' }],
  });
  await fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(router.delete).toHaveBeenCalledWith('/admin/resident_turns/42', { preserveScroll: true });
});
