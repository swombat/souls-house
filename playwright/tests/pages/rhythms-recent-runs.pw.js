import { test, expect } from '@playwright/experimental-ct-svelte';
import RhythmsIndex from '../../../app/frontend/pages/rhythms/index.svelte';

const lume = { id: 'lume', name: 'Lume', colour: 'orange' };
const mira = { id: 'mira', name: 'Mira', colour: 'teal' };

function run(id, day, listed = false) {
  return {
    id,
    title: `House watch — ${day} Oct 2026`,
    scheduled_for: `2026-10-${String(day).padStart(2, '0')}T07:30:00Z`,
    chat_url: `/accounts/acc/chats/${id}`,
    listed,
  };
}

const rhythms = [
  {
    id: 'r1',
    title: 'House watch: the long way round',
    schedule_description: 'Every day at 09:30 · Madrid',
    state: 'active',
    residents: [lume],
    creator: { name: 'Lume' },
    next_run_at: '2026-10-08T07:30:00Z',
    timezone_identifier: 'Europe/Madrid',
    holds: [],
    recent_runs: [run('c7', 7), run('c6', 6, true), run('c5', 5), run('c4', 4), run('c3', 3)],
  },
  {
    id: 'r2',
    title: 'Sunday review',
    schedule_description: 'Every Sunday at 18:00 · Madrid',
    state: 'active',
    residents: [lume, mira],
    creator: { name: 'Daniel' },
    next_run_at: '2026-10-11T16:00:00Z',
    timezone_identifier: 'Europe/Madrid',
    holds: [],
    recent_runs: [],
  },
];

for (const [name, viewport] of [
  ['desktop', { width: 1100, height: 760 }],
  ['mobile', { width: 390, height: 844 }],
]) {
  test(`rhythms list shows recent conversations inline (${name})`, async ({ mount, page }) => {
    await page.setViewportSize(viewport);
    const component = await mount(RhythmsIndex, { props: { account: { id: 'acc' }, rhythms } });
    const list = component.getByRole('list', { name: 'Recent conversations' });
    await expect(list.getByRole('link')).toHaveCount(5);
    await expect(list.getByRole('link').nth(1)).toContainText('in your list');
    await page.screenshot({ path: `tmp/rhythms-recent-runs-${name}.png`, fullPage: true });
  });
}
