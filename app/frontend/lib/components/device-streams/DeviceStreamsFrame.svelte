<script>
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  // Account-scoped stream pages sit under Integrations in account settings.
  // The personal recovery pages have no account: they keep working after you leave one.
  let { account = null, title, description = null, children } = $props();
</script>

{#if account}
  <AccountSettingsLayout {account} active="integrations" {title} {description}>
    {@render children()}
  </AccountSettingsLayout>
{:else}
  <div class="p-8 max-w-4xl mx-auto">
    <div class="mb-8">
      <p class="text-sm text-muted-foreground">Your data · All accounts</p>
      <h1 class="text-3xl font-bold">{title}</h1>
      {#if description}
        <p class="mt-1 text-muted-foreground">{description}</p>
      {/if}
    </div>
    <div class="space-y-6">
      {@render children()}
    </div>
  </div>
{/if}
