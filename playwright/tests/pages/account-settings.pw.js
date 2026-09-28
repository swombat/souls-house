import { test, expect } from '@playwright/experimental-ct-svelte';
import AccountSettingsHarness from '../../AccountSettingsHarness.svelte';

test.describe('Account settings', () => {
  test('shows per-account AI provider keys without exposing saved values', async ({ mount }) => {
    const component = await mount(AccountSettingsHarness, {
      props: {
        account: {
          id: 2,
          name: 'Test Team',
          use_system_ai_credentials: true,
        },
        ai_api_keys_configured: {
          openrouter: true,
          anthropic: false,
          openai: false,
          gemini: false,
          xai: false,
          moonshot: true,
        },
        can_manage_ai_credentials: true,
      },
    });

    await expect(component.getByRole('heading', { name: 'Resident API Keys' })).toBeVisible();
    await expect(component.getByLabel('OpenRouter')).toHaveAttribute('type', 'password');
    await expect(component.getByLabel('OpenRouter')).toHaveValue('');
    await expect(component.getByLabel('OpenRouter')).toHaveAttribute('placeholder', 'Enter a replacement key');
    await expect(component.getByLabel('Moonshot')).toBeVisible();
    await expect(component.getByText('Set', { exact: true })).toHaveCount(2);
    await expect(component.getByText('Not set', { exact: true })).toHaveCount(6);
    await expect(component.getByText('Shared AI keys are available as a fallback')).toBeVisible();
    await expect(component.getByText('New Conversation Default')).toBeHidden();

    await component.getByRole('button', { name: 'Remove' }).first().click();
    await expect(component.getByText('Will be removed')).toBeVisible();
    await expect(component.getByLabel('OpenRouter')).toBeDisabled();
  });

  test('shows key status read-only to account members', async ({ mount }) => {
    const component = await mount(AccountSettingsHarness, {
      props: {
        account: {
          id: 2,
          name: 'Test Team',
          use_system_ai_credentials: false,
        },
        ai_api_keys_configured: {
          openrouter: true,
          anthropic: false,
          openai: false,
          gemini: false,
          xai: false,
          moonshot: false,
        },
        can_manage_ai_credentials: false,
      },
    });

    await expect(component.getByText('Set', { exact: true })).toHaveCount(1);
    await expect(component.getByLabel('OpenRouter')).toBeDisabled();
    await expect(component.getByRole('button', { name: 'Remove' })).toHaveCount(0);
    await expect(
      component.getByText('Only account owners and administrators can change resident API keys.')
    ).toBeVisible();
  });
});
