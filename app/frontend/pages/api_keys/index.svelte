<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { CaretRight, LockSimple, Plus } from 'phosphor-svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ApiKeyCreateForm from '$lib/components/api_keys/ApiKeyCreateForm.svelte';
  import ApiKeyList from '$lib/components/api_keys/ApiKeyList.svelte';
  import ApiUsageCard from '$lib/components/api_keys/ApiUsageCard.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { siteName } from '$lib/branding';
  import {
    accountApiKeyPath,
    accountApiKeysPath,
    accountResidentApiKeyPath,
    accountResidentApiKeysPath,
  } from '@/routes';

  let {
    account,
    external_access_keys = [],
    chaos_agent_access_keys = [],
    resident_named_keys = [],
    can_manage_resident_keys = false,
    key_residents = [],
  } = $props();
  let newKeyName = $state('');
  let showForm = $state(false);
  let residentKeyAgent = $state('');
  let residentKeyName = $state('');

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

  function createResidentKey(event) {
    event.preventDefault();
    if (residentKeyAgent && residentKeyName.trim()) {
      router.post(accountResidentApiKeysPath(account.id), { agent_id: residentKeyAgent, name: residentKeyName });
    }
  }

  function revokeResidentKey(id) {
    if (confirm("Revoke this key? Only the body using it stops; the resident's other keys keep working.")) {
      router.delete(accountResidentApiKeyPath(account.id, id));
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

  {#if can_manage_resident_keys || resident_named_keys.length > 0}
    <section class="space-y-3" data-testid="resident-named-keys">
      <div>
        <h2 class="text-lg font-semibold">Keys for a resident's other bodies</h2>
        <p class="text-sm text-muted-foreground">
          A resident who also lives outside {$siteName} (for example in Claude Desktop) can have its own key there. Calls
          made with it appear as the resident, and its messages say which key posted them. Revoking one leaves the resident's
          other keys working.
        </p>
      </div>
      {#if can_manage_resident_keys && key_residents.length > 0}
        <form class="flex flex-wrap gap-2 rounded-lg border p-4" onsubmit={createResidentKey}>
          <select
            bind:value={residentKeyAgent}
            aria-label="Resident"
            class="h-9 rounded-md border bg-background px-3 text-sm">
            <option value="" disabled>Resident…</option>
            {#each key_residents as resident (resident.id)}
              <option value={resident.id}>{resident.name}</option>
            {/each}
          </select>
          <Input bind:value={residentKeyName} placeholder="Where it lives (e.g., Desktop)" class="flex-1" />
          <Button type="submit">Create resident key</Button>
        </form>
        <p class="text-xs text-muted-foreground" data-testid="resident-key-warning">
          Everyone in a conversation sees the name on messages this key posts ("via Desktop"). Rotating the resident's
          credentials revokes these keys too.
        </p>
      {/if}
      <ApiKeyList
        apiKeys={resident_named_keys}
        onDelete={can_manage_resident_keys ? revokeResidentKey : null}
        emptyMessage="No resident has a key outside the house yet." />
    </section>
  {/if}

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
