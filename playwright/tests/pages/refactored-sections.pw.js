import { test, expect } from '@playwright/experimental-ct-svelte';
import Subscription from '../../../app/frontend/lib/components/agents/AgentProviderSubscriptionPanel.svelte';
import PersonalServices from '../../../app/frontend/pages/accounts/personal_services.svelte';

test('subscription code input belongs to the ceremony and completion selects subscription mode', async ({
  mount,
  page,
}) => {
  let submitted;
  let status = 'awaiting_code';
  await page.route('**/provider_subscription**', async (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith('provider_subscription_usage')) {
      return route.fulfill({ json: { status: 'unknown' } });
    }
    if (url.searchParams.has('capabilities')) {
      return route.fulfill({ json: { providers: { anthropic: { oauth_account: true } } } });
    }
    if (url.pathname.endsWith('/code')) {
      submitted = route.request().postDataJSON();
      status = 'connected';
      return route.fulfill({ json: { status: 'finalizing' } });
    }
    return route.fulfill({
      json: {
        status,
        verification_url: 'https://example.invalid/synthetic-signin',
        expires_at: new Date(Date.now() + 300000).toISOString(),
      },
    });
  });
  const component = await mount(Subscription, {
    props: {
      account: { id: 'synthetic-account' },
      canManage: true,
      subscriptionAgent: {
        id: 'synthetic-resident',
        name: 'Synthetic',
        provider: 'anthropic',
        provider_name: 'Anthropic',
        available: true,
        auth_mode: 'api_key',
        connection: {},
      },
    },
  });
  await component.getByRole('button', { name: 'Connect Claude subscription' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByPlaceholder('Paste the localhost callback URL or code').fill('synthetic-authorization-code');
  await dialog.getByRole('button', { name: 'Submit code' }).click();
  await expect.poll(() => submitted).toEqual({ provider: 'anthropic', code: 'synthetic-authorization-code' });
  await expect(dialog.getByText(/Connected successfully/)).toBeVisible();
  await dialog.getByRole('button', { name: 'Done' }).click();
  await expect(dialog).toBeHidden();
  await expect(component.getByRole('button', { name: 'Claude Code clamp', exact: true })).toBeEnabled();
  await expect(component.getByRole('button', { name: 'Reconnect' })).toBeVisible();
});

test('personal service cards retain resident provisioning controls after extraction', async ({ mount, page }) => {
  let requestBody;
  await page.route('**/synthetic-access', async (route) => {
    requestBody = route.request().postDataJSON();
    return route.fulfill({ json: {} });
  });
  const component = await mount(PersonalServices, {
    props: {
      account: { id: 'synthetic-account', name: 'Synthetic account' },
      services: [],
      connections: [
        {
          id: 'synthetic-connection',
          label: 'Synthetic repository',
          provider: 'github',
          status: 'connected',
          residents: [
            {
              id: 'synthetic-resident',
              name: 'Synthetic resident',
              enabled: false,
              access_update_url: '/synthetic-access',
            },
          ],
        },
      ],
    },
  });
  await component.getByRole('switch', { name: 'Enable Synthetic repository for Synthetic resident' }).click();
  await expect.poll(() => requestBody).toEqual({ enabled: true });
});
