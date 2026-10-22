import { render, fireEvent, screen } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import { router } from '@inertiajs/svelte';
import Voices from './voices.svelte';

const voice = (id, name, extra = {}) => ({
  id,
  name,
  used_in: 1,
  remember: true,
  remembered: false,
  recordings: 0,
  ...extra,
});
const props = {
  account: { id: 'home' },
  voices: [voice('ants', 'Ants'), voice('hiron', 'Ant Hiron'), voice('priya', 'Priya')],
};

test('merge searches the other speakers, offers both names, and posts the choice', async () => {
  render(Voices, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Merge with other speaker' }));
  await fireEvent.input(screen.getByRole('textbox', { name: 'Search for the other speaker' }), {
    target: { value: 'hir' },
  });
  const candidates = screen.getAllByTestId('voice-merge-candidate');
  expect(candidates).toHaveLength(1);
  await fireEvent.click(candidates[0]);

  expect(screen.getByRole('radio', { name: 'Ant Hiron' })).toBeChecked();
  await fireEvent.click(screen.getByRole('radio', { name: 'Ants' }));
  await fireEvent.click(screen.getByTestId('voice-merge-confirm'));
  const [url, data] = router.post.mock.calls.at(-1);
  expect(url).toBe('/accounts/home/field/voices/ants/merge');
  expect(data).toEqual({ into: 'hiron', name: 'Ants' });
});
