<script>
  import { page } from '@inertiajs/svelte';
  import ComputersPage from '../app/frontend/pages/accounts/computers.svelte';

  let { account, devices = [], can_manage = true, warnings = {} } = $props();

  page.set({
    props: { account, devices, can_manage, warnings, flash: {} },
    component: 'accounts/computers',
    url: `/accounts/${account.id}/computers`,
    version: 'test',
  });
</script>

<ComputersPage {account} {devices} {can_manage} {warnings} />
