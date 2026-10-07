<script>
  import { page } from '@inertiajs/svelte';
  import AccountApiKeysPage from '../app/frontend/pages/accounts/agent_api_keys.svelte';

  let { account, ai_api_keys_configured = {}, can_manage_ai_credentials = false, subscription_agents = [] } = $props();

  page.set({
    props: {
      account,
      ai_api_keys_configured,
      can_manage_ai_credentials,
      subscription_agents,
      flash: {},
    },
    component: 'accounts/agent_api_keys',
    url: `/accounts/${account.id}/agent_api_keys`,
    version: 'test',
  });
</script>

<!-- Inertia passes page data as component props; the page store still supplies flash. -->
<AccountApiKeysPage {account} {ai_api_keys_configured} {can_manage_ai_credentials} {subscription_agents} />
