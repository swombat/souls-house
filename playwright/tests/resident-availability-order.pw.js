import { test, expect } from '@playwright/experimental-ct-svelte';
import AgentTriggerBar from '../../app/frontend/lib/components/chat/AgentTriggerBar.svelte';
import GroupChatAgentPicker from '../../app/frontend/lib/components/chat/GroupChatAgentPicker.svelte';

const subscription = {
  available: true,
  auth_mode: 'oauth_account',
  provider: 'openai',
  connection: { status: 'connected' },
};

function residents(accountSuffix) {
  return [
    { id: `zed-${accountSuffix}`, name: 'Zed' },
    { id: `low-${accountSuffix}`, name: 'Low', provider_subscription: subscription },
    { id: `high-${accountSuffix}`, name: 'High', provider_subscription: subscription },
    { id: `amy-${accountSuffix}`, name: 'amy' },
  ];
}

async function routeUsage(page) {
  await page.route('**/residents/*/provider_subscription_usage', (route) => {
    const percent = route.request().url().includes('/low-') ? 15 : 70;
    return route.fulfill({
      json: { windows: [{ id: 'session', remaining_percent: percent, resets_at: '2026-10-18T00:00:00Z' }] },
    });
  });
}

async function buttonNames(component, names) {
  const labels = await component.getByRole('button').allTextContents();
  return labels.map((label) => names.find((name) => label.includes(name))).filter(Boolean);
}

test('ask bar orders residents by weekly availability, then by name', async ({ mount, page }) => {
  await routeUsage(page);
  const component = await mount(AgentTriggerBar, {
    props: { accountId: 'order-bar', chatId: 'chat', showUsage: true, agents: residents('bar') },
  });
  await expect(component.getByRole('button', { name: /^Low/ })).toHaveAccessibleName('Low (15% left)');
  await expect(component.getByRole('button', { name: /^High/ })).toHaveAccessibleName('High (70% left)');
  await expect.poll(() => buttonNames(component, ['High', 'Low', 'amy', 'Zed'])).toEqual(['High', 'Low', 'amy', 'Zed']);
});

test('ask bar falls back to alphabetical order with no subscriptions', async ({ mount }) => {
  const component = await mount(AgentTriggerBar, {
    props: {
      accountId: 'order-plain',
      chatId: 'chat',
      agents: [
        { id: 'c', name: 'Cleo' },
        { id: 'a', name: 'ash' },
        { id: 'b', name: 'Bram' },
      ],
    },
  });
  await expect.poll(() => buttonNames(component, ['ash', 'Bram', 'Cleo'])).toEqual(['ash', 'Bram', 'Cleo']);
});

test('new chat picker orders residents by weekly availability, then by name', async ({ mount, page }) => {
  await routeUsage(page);
  const component = await mount(GroupChatAgentPicker, {
    props: { accountId: 'order-picker', showUsage: true, agents: residents('picker') },
  });
  await expect(component.getByRole('button', { name: /^Low/ })).toContainText('Low (15% left)');
  await expect(component.getByRole('button', { name: /^High/ })).toContainText('High (70% left)');
  await expect.poll(() => buttonNames(component, ['High', 'Low', 'amy', 'Zed'])).toEqual(['High', 'Low', 'amy', 'Zed']);
});
