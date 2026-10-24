import { test, expect } from '@playwright/experimental-ct-svelte';
import AgentIntegrationsHarness from '../../AgentIntegrationsHarness.svelte';

test.describe('Agent integrations', () => {
  test('shows Telegram in the available integrations list', async ({ mount }) => {
    const component = await mount(AgentIntegrationsHarness, {
      props: {
        agent: {
          name: 'Lume',
          telegram_configured: false,
          telegram_bot_username: null,
        },
      },
    });

    await expect(component.getByRole('heading', { name: 'Integrations' })).toBeVisible();
    await expect(component.getByRole('heading', { name: 'Telegram' })).toBeVisible();
    await expect(component.getByLabel('Bot username')).not.toBeVisible();
    await expect(component.getByRole('button', { name: 'Set up' })).toBeVisible();
  });

  test('teaches the user how to create a Telegram bot', async ({ mount }) => {
    const component = await mount(AgentIntegrationsHarness, {
      props: {
        agent: {
          name: 'Lume',
          telegram_configured: false,
          telegram_bot_username: null,
        },
      },
    });

    await component.getByRole('button', { name: 'Set up' }).click();
    await expect(component.getByRole('heading', { name: 'Create a Telegram bot' })).toBeVisible();
    await expect(component.getByRole('link', { name: '@BotFather in Telegram' })).toHaveAttribute(
      'href',
      'https://t.me/botfather'
    );
    await expect(component).toContainText('/newbot');
    await expect(component.getByLabel('Bot username')).toHaveAttribute('required', '');
    await expect(component.getByLabel('Bot token')).toHaveAttribute('required', '');
    await expect(component.getByRole('button', { name: 'Save Telegram settings' })).toBeVisible();
  });

  test('shows settings for a connected Telegram bot', async ({ mount }) => {
    const component = await mount(AgentIntegrationsHarness, {
      props: {
        agent: {
          name: 'Lume',
          telegram_configured: true,
          telegram_bot_username: 'lume_bot',
        },
        telegramDeepLink: 'https://t.me/lume_bot?start=registration-token',
        telegramSubscriberCount: 2,
      },
    });

    await expect(component).toContainText('Connected');
    await component.getByRole('button', { name: 'Settings' }).click();
    await expect(component).toContainText('Telegram is connected as @lume_bot');
    await expect(component.getByLabel('Bot username')).toHaveValue('lume_bot');
    await expect(component.getByLabel('Bot token')).not.toHaveAttribute('required', '');
    await expect(component).toContainText('2 subscribers connected');
    // Even a supplied bearer link stays hidden until the user explicitly requests it.
    await expect(component).not.toContainText('https://t.me/lume_bot?start=registration-token');
    await expect(component.getByRole('button', { name: 'Reveal registration link' })).toBeEnabled();
  });
});
