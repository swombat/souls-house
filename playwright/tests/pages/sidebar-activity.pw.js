import { test, expect } from '@playwright/experimental-ct-svelte';
import ChatSidebarItem from '../../../app/frontend/lib/components/chat/ChatSidebarItem.svelte';

test('sidebar ring is visible without hovering, rotates independently, and respects reduced motion', async ({
  mount,
  page,
}) => {
  const chat = {
    id: 'chat-one',
    title: 'A resident at work',
    manual_responses: true,
    message_count: 3,
    participants_json: [
      { id: 'mira', type: 'agent', name: 'Mira', icon: 'eye', colour: 'violet' },
      { id: 'peer', type: 'agent', name: 'Peer', icon: 'leaf', colour: 'green' },
    ],
    working_agent_ids: ['mira'],
  };
  const component = await mount(ChatSidebarItem, { props: { chat, accountId: 'account-one' } });
  const working = component.getByRole('img', { name: 'Mira is working' });
  const ring = working.locator('.working-ring');
  await expect(working).toHaveCSS('opacity', '1');
  await expect(component.getByRole('img', { name: 'Peer' })).toHaveCSS('opacity', '0.2');
  await expect(ring).toHaveCSS('animation-duration', '1s');
  await expect(working).toHaveCSS('transform', 'none');
  await expect.poll(() => ring.evaluate((el) => getComputedStyle(el).transform)).not.toBe('none');
  await page.screenshot({ path: 'test-results/sidebar-working.png' });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(ring).toHaveCSS('animation-name', 'none');
  await expect(ring).toHaveCSS('border-right-color', await ring.evaluate((el) => getComputedStyle(el).borderTopColor));
  await component.update({ props: { chat: { ...chat, working_agent_ids: [] }, accountId: 'account-one' } });
  await expect(component.locator('.working-ring')).toHaveCount(0);
});
