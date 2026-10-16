import { test, expect } from '@playwright/experimental-ct-svelte';
import FieldTweetStreamPanel from '../../app/frontend/lib/components/field/FieldTweetStreamPanel.svelte';

const source = {
  id: 'source-one',
  handle: 'example',
  url: 'https://x.com/example',
  include_replies: true,
  include_quotes: true,
  include_reposts: false,
  own_monthly_usd_limit: '5.00',
  funding: 'own',
  state: 'active',
  state_reason: null,
  imported_today: 2,
  daily_import_cap: 50,
  backlog: 0,
};
const stream = {
  source,
  funding: 'own',
  integration_url: '/accounts/example/integrations',
  house_available: false,
  daily_import_cap: 50,
  account_monthly_usd_ceiling: '1',
  poll_minutes: 15,
};

test('live presentation keeps a dirty stream form but resets replacement identities', async ({
  mount,
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1100, height: 900 });
  const props = { accountId: 'account-one', stream };
  const panel = await mount(FieldTweetStreamPanel, { props });
  const form = panel.getByTestId('tweet-stream-settings-form');
  const replies = form.getByRole('checkbox', { name: 'Include its replies', exact: true });
  const limit = form.getByLabel('Monthly limit on your TwitterAPI.io spend (USD)');
  await replies.uncheck();
  await limit.fill('7.25');

  const refreshed = {
    ...stream,
    source: { ...source, state: 'paused', imported_today: 9, backlog: 3 },
  };
  await panel.update({ props: { ...props, stream: refreshed } });
  await expect(panel.getByTestId('field-tweet-stream-state')).toContainText('Paused');
  await expect(panel).toContainText('Imported today: 9 of 50');
  await expect(panel).toContainText('3 waiting in the backlog');
  await expect(replies).not.toBeChecked();
  await expect(limit).toHaveValue('7.25');
  await page.screenshot({ path: testInfo.outputPath('tweet-stream-draft.png'), fullPage: true });

  await panel.update({
    props: { ...props, stream: { ...stream, source: { ...source, id: 'replacement', own_monthly_usd_limit: '11' } } },
  });
  await expect(replies).toBeChecked();
  await expect(limit).toHaveValue('11');
  await replies.uncheck();
  await panel.update({ props: { ...props, accountId: 'account-two' } });
  await expect(replies).toBeChecked();
  await expect(limit).toHaveValue(/^5(?:\.0+)?$/);
});

test('a pristine form accepts remote settings and a follow draft survives funding refresh', async ({ mount }) => {
  const props = { accountId: 'account-one', stream };
  const panel = await mount(FieldTweetStreamPanel, { props });
  const form = panel.getByTestId('tweet-stream-settings-form');
  await panel.update({
    props: {
      ...props,
      stream: { ...stream, source: { ...source, include_replies: false, own_monthly_usd_limit: '12' } },
    },
  });
  await expect(form.getByRole('checkbox', { name: 'Include its replies', exact: true })).not.toBeChecked();
  await expect(form.getByLabel('Monthly limit on your TwitterAPI.io spend (USD)')).toHaveValue('12');

  await panel.update({ props: { ...props, stream: { ...stream, source: null } } });
  const handle = panel.getByRole('textbox', { name: 'Follow an X handle', exact: true });
  await handle.fill('unfinished_handle');
  await panel.update({ props: { ...props, stream: { ...stream, source: null, poll_minutes: 30 } } });
  await expect(handle).toHaveValue('unfinished_handle');
});
