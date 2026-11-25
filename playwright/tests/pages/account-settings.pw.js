import { test, expect } from '@playwright/experimental-ct-svelte';
import AccountSettingsHarness from '../../AccountSettingsHarness.svelte';

test.describe('Account settings', () => {
  test('shows OpenRouter recommended, fallback provider rows, and resident links without exposing saved values', async ({
    mount,
  }) => {
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
          zai: false,
          moonshot: true,
          minimax: false,
        },
        can_manage_ai_credentials: true,
        residents: [
          { id: 'lume', name: 'Lume' },
          { id: 'mira', name: 'Mira' },
        ],
      },
    });

    await expect(component.getByRole('heading', { name: 'Model keys', exact: true })).toBeVisible();
    await expect(component.getByText('Test Team · Account settings', { exact: true })).toBeVisible();
    await expect(component.getByText('Recommended', { exact: true })).toBeVisible();
    await expect(
      component.getByText('Covers image generation and any model without a direct provider key.')
    ).toBeVisible();

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
    for (const label of ['Anthropic', 'Gemini', 'OpenAI', 'xAI', 'Z.ai', 'Kimi Code', 'MiniMax']) {
      await expect(component.getByLabel(label, { exact: true })).toBeVisible();
    }
    await expect(component.getByText(/Standard Moonshot platform \(PAYG\) keys do not work/)).toBeVisible();
    await expect(component.getByText('Set', { exact: true })).toHaveCount(2);
    await expect(component.getByText('Not set', { exact: true })).toHaveCount(6);
    await expect(component.getByText('Shared AI keys are available as a fallback')).toBeVisible();
    await expect(component.getByText('Provider subscription accounts')).toHaveCount(0);
    await expect(component.getByText(/Antigravity/)).toHaveCount(0);
    await expect(component.getByText(/Claude Code clamping/)).toHaveCount(0);
    await expect(component.getByRole('link', { name: 'Lume', exact: true })).toHaveAttribute(
      'href',
      '/accounts/2/residents/lume/edit?tab=settings'
    );
    await expect(component.getByRole('link', { name: 'Mira', exact: true })).toHaveAttribute(
      'href',
      '/accounts/2/residents/mira/edit?tab=settings'
    );
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
        residents: [],
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
      component.getByText("Provider subscriptions are connected on a resident's own settings.")
    ).toBeVisible();
    await expect(component.getByRole('link', { name: 'Residents', exact: true })).toHaveAttribute(
      'href',
      '/accounts/2/residents'
    );
    await expect(
      component.getByText('Only account owners and administrators can change model API keys.')
    ).toBeVisible();
  });
});
