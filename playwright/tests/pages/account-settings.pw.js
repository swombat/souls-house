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

    await expect(component.getByRole('heading', { name: 'Model API keys', exact: true })).toBeVisible();
    await expect(component.getByText('Test Team · Account settings', { exact: true })).toBeVisible();
    await expect(component.getByRole('link', { name: 'Model API keys', exact: true })).toHaveAttribute(
      'href',
      '/accounts/2/agent_api_keys'
    );
    const keyInputs = component.locator('input[type="password"]');
    await expect(keyInputs).toHaveCount(8);
    for (const input of await keyInputs.all()) {
      await expect(input).toHaveValue('');
      await expect(input).toBeEnabled();
    }
    await expect(component.getByLabel('OpenRouter API key', { exact: true })).toHaveAttribute(
      'placeholder',
      'Enter a replacement key'
    );
    await expect(component.getByLabel('Moonshot (Kimi)', { exact: true })).toBeVisible();
    await expect(component.getByText('Set', { exact: true })).toHaveCount(2);
    await expect(component.getByText('Not set', { exact: true })).toHaveCount(6);
    await expect(component.getByText('Shared AI keys are available as a fallback')).toBeVisible();
    await expect(component.getByText('New Conversation Default')).toBeHidden();
    await expect(component.getByRole('button', { name: 'Save model API keys', exact: true })).toBeVisible();
    await component.getByText('How residents receive these keys', { exact: true }).click();
    await expect(
      component.getByText(/These are separate from the .+ API keys, which let outside tools connect to/)
    ).toBeVisible();

    await component.getByRole('button', { name: 'Remove' }).first().click();
    await expect(component.getByText('Will be removed')).toBeVisible();
    await expect(component.getByLabel('OpenRouter API key', { exact: true })).toBeDisabled();
    await component.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(component.getByLabel('OpenRouter API key', { exact: true })).toBeEnabled();
    await expect(component.getByLabel('OpenRouter API key', { exact: true })).toHaveValue('');
    await expect(component.getByText('Set', { exact: true })).toHaveCount(2);
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
    const keyInputs = component.locator('input[type="password"]');
    await expect(keyInputs).toHaveCount(8);
    for (const input of await keyInputs.all()) {
      await expect(input).toBeDisabled();
      await expect(input).toHaveValue('');
    }
    await expect(component.getByRole('button', { name: 'Remove' })).toHaveCount(0);
    await expect(component.getByRole('button', { name: 'Save model API keys', exact: true })).toHaveCount(0);
    await expect(component.getByText('Shared AI keys are available as a fallback')).toHaveCount(0);
    await expect(
      component.getByText('Only account owners and administrators can change model API keys.')
    ).toBeVisible();
  });
});
