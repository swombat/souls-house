<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { CaretRight, LockSimple, Plus } from 'phosphor-svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ApiKeyCreateForm from '$lib/components/api_keys/ApiKeyCreateForm.svelte';
  import ApiKeyList from '$lib/components/api_keys/ApiKeyList.svelte';
  import ApiUsageCard from '$lib/components/api_keys/ApiUsageCard.svelte';
  import DisabledResidents from '$lib/components/api_keys/DisabledResidents.svelte';
  import { partitionResidents, disabledKeyResidentCount } from '$lib/components/api_keys/resident-visibility';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { siteName } from '$lib/branding';
  import { accountApiKeyPath, accountApiKeysPath } from '@/routes';

  let { account, external_access_keys = [], resident_keys = [], key_residents = [] } = $props();
  let newKeyName = $state('');
  let showForm = $state(false);
  let residents = $derived(partitionResidents(key_residents));
  let keys = $derived(partitionResidents(resident_keys));
  let disabledKeyResidents = $derived(disabledKeyResidentCount(resident_keys));

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

<svelte:head>
  <title>{$siteName} API · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="house_api"
  title={`${$siteName} API`}
  description={`Keys that let outside tools and agents connect to ${account.name} in ${$siteName}.`}>
  {#snippet actions()}
    <Button onclick={() => (showForm = !showForm)}>
      <Plus class="mr-2" size={16} />
      Create Key
    </Button>
  {/snippet}

  <FlashMessages flash={$page.props.flash} />

  {#if showForm}
    <ApiKeyCreateForm bind:name={newKeyName} onSubmit={createKey} />
  {/if}

  <section class="space-y-3">
    <div>
      <h2 class="text-lg font-semibold">Keys that act as you</h2>
      <p class="text-sm text-muted-foreground">
        These keys act as you. Messages posted with them appear as your user account.
      </p>
    </div>
    <ApiKeyList
      apiKeys={external_access_keys}
      onDelete={deleteKey}
      emptyMessage="No keys yet. Create one for an external tool." />
  </section>

  <ApiUsageCard />

  {#if key_residents.length > 0}
    <section class="space-y-3">
      <div>
        <h2 class="text-lg font-semibold">Connect a resident's other body</h2>
        <p class="text-sm text-muted-foreground">Manage these keys in the resident's Settings.</p>
      </div>
      <div class="flex flex-wrap gap-2">
        {#each residents.active as resident (resident.id)}
          <Button href={resident.settings_url} variant="outline">{resident.name}'s Settings</Button>
        {/each}
      </div>
      <DisabledResidents count={residents.disabled.length}>
        <div class="flex flex-wrap gap-2">
          {#each residents.disabled as resident (resident.id)}
            <Button href={resident.settings_url} variant="outline">{resident.name}'s Settings</Button>
          {/each}
        </div>
      </DisabledResidents>
    </section>
  {/if}

  <details class="group rounded-lg border border-dashed bg-muted/20 text-sm">
    <summary class="flex cursor-pointer list-none items-center gap-2 px-4 py-3 text-muted-foreground">
      <CaretRight size={14} class="transition-transform group-open:rotate-90" />
      <LockSimple size={16} />
      <span class="font-medium">All resident keys</span>
      <span class="ml-auto rounded-full bg-muted px-2 py-0.5 text-xs">Read-only</span>
    </summary>
    <div class="space-y-3 border-t border-dashed px-4 py-4">
      <p class="text-muted-foreground">
        These keys act as residents, not as you. This includes house keys and keys for other bodies. Manage keys for
        other bodies in the resident's Settings; house keys are system-managed.
      </p>
      <div class="opacity-80">
        <ApiKeyList
          apiKeys={keys.active}
          emptyMessage={keys.disabled.length ? 'No active residents have keys yet.' : 'No residents have keys yet.'} />
        <DisabledResidents count={disabledKeyResidents}>
          <ApiKeyList apiKeys={keys.disabled} />
        </DisabledResidents>
      </div>
    </div>
  </details>
</AccountSettingsLayout>
