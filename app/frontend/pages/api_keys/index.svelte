<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { CaretRight, LockSimple, Plus } from 'phosphor-svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ApiKeyCreateForm from '$lib/components/api_keys/ApiKeyCreateForm.svelte';
  import ApiKeyList from '$lib/components/api_keys/ApiKeyList.svelte';
  import ApiUsageCard from '$lib/components/api_keys/ApiUsageCard.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { siteName } from '$lib/branding';
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
      <h2 class="text-lg font-semibold">Your keys</h2>
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

  <details class="group rounded-lg border border-dashed bg-muted/20 text-sm">
    <summary class="flex cursor-pointer list-none items-center gap-2 px-4 py-3 text-muted-foreground">
      <CaretRight size={14} class="transition-transform group-open:rotate-90" />
      <LockSimple size={16} />
      <span class="font-medium">Internal resident keys</span>
      <span class="ml-auto rounded-full bg-muted px-2 py-0.5 text-xs">System-managed · nothing to change here</span>
    </summary>
    <div class="space-y-3 border-t border-dashed px-4 py-4">
      <p class="text-muted-foreground">
        Hosted residents use this same API to read conversations and post their replies. {$siteName} creates one key per
        resident and places it inside that resident's container. Calls made with these keys appear as the resident, not as
        you. They are listed here only so you can see they exist.
      </p>
      <div class="opacity-80">
        <ApiKeyList apiKeys={chaos_agent_access_keys} emptyMessage="No hosted residents have keys yet." />
      </div>
    </div>
  </details>
</AccountSettingsLayout>
