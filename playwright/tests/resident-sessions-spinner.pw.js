import { expect, test } from '@playwright/experimental-ct-svelte';
import AgentCard from '../../app/frontend/lib/components/agents/AgentCard.svelte';

const agent = {
  id: 'lume',
  name: 'Lume',
  colour: 'orange',
  active: true,
  model_id: 'claude-opus-5-5',
  model_label: 'Claude Opus 5.5',
  owner_email: 'daniel@example.com',
  account_name: 'Daniel',
  hosting: { kind: 'local', state: 'ready' },
  mnemodyne_node_count: 1234,
  mnemodyne_edge_count: 2345,
  journal_entry_stats: { count: 27, status: 'measured' },
  activity: [],
  integrations: [],
};

test('the card header shows the running total and one coloured ring per kind', async ({ mount, page }) => {
  await page.setViewportSize({ width: 420, height: 320 });
  const component = await mount(AgentCard, {
    props: { agent, sessions: { chat: 2, telegram: 1, other: 1 }, admin: true, showActions: false, accountId: 'a' },
  });
  const badge = component.getByTestId('resident-sessions');
  await expect(badge).toHaveText('4');
  await expect(badge.getByRole('img')).toHaveAccessibleName('4 active sessions: 2 chat · 1 Telegram · 1 other');

  const rings = badge.getByTestId('resident-sessions-ring');
  await expect(rings).toHaveCount(3);
  const colours = await rings.evaluateAll((elements) =>
    elements.map((element) => getComputedStyle(element).borderTopColor)
  );
  expect(colours.every((colour) => colour !== 'rgba(0, 0, 0, 0)')).toBe(true);
  expect(new Set(colours).size).toBe(3);

  if (process.env.RESIDENT_SESSIONS_SHOT) await component.screenshot({ path: process.env.RESIDENT_SESSIONS_SHOT });
});
