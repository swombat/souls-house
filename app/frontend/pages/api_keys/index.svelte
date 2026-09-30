<script>
  import { router } from '@inertiajs/svelte';
  import ApiKeyCreateForm from '$lib/components/api_keys/ApiKeyCreateForm.svelte';
  import ApiKeyHeader from '$lib/components/api_keys/ApiKeyHeader.svelte';
  import ApiKeyList from '$lib/components/api_keys/ApiKeyList.svelte';
  import ApiUsageCard from '$lib/components/api_keys/ApiUsageCard.svelte';
  import { accountApiKeyPath, accountApiKeysPath } from '@/routes';

  let { account, external_access_keys = [], chaos_agent_access_keys = [] } = $props();
  let newKeyName = $state('');
  let showForm = $state(false);

  function createKey() {
    if (newKeyName.trim()) {
      router.post(accountApiKeysPath(account.id), { name: newKeyName });
    }
  }

  function deleteKey(id) {
    if (confirm('Revoke this API key? Applications using it will stop working.')) {
      router.delete(accountApiKeyPath(account.id, id));
    }
  }
</script>

<div class="container mx-auto p-8 max-w-4xl">
  <ApiKeyHeader {account} onCreate={() => (showForm = !showForm)} />

  {#if showForm}
    <ApiKeyCreateForm bind:name={newKeyName} onSubmit={createKey} />
  {/if}

  <div class="space-y-8">
    <section class="space-y-3">
      <div>
        <h2 class="text-lg font-semibold">Your External Access Keys</h2>
        <p class="text-sm text-muted-foreground">
          These keys act as you. Messages posted with them appear as your user account.
        </p>
      </div>
      <ApiKeyList
        apiKeys={external_access_keys}
        onDelete={deleteKey}
        emptyMessage="No personal external access keys yet. Create one for an external tool." />
    </section>

    <section class="space-y-3">
      <div>
        <h2 class="text-lg font-semibold">Chaos Resident Access</h2>
        <p class="text-sm text-muted-foreground">
          Each system-managed key is bound to the named resident. Calls and messages made with it appear as that resident, not
          as you.
        </p>
      </div>
      <ApiKeyList apiKeys={chaos_agent_access_keys} emptyMessage="No Chaos residents have account access keys yet." />
    </section>
  </div>

  <ApiUsageCard />
</div>
