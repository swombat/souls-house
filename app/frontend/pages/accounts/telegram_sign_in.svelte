<script>
  import { page } from '@inertiajs/svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ConnectionTelegramLogin from '$lib/components/settings/connection-telegram-login.svelte';
  import { Button } from '$lib/components/shadcn/button';

  // The focused page Connect Telegram opens: the same sign-in as the
  // Integrations card (QR, phone number and code, two-step password), on its
  // own, then a clear way back once it is connected.
  let { account, connection, integrations_url } = $props();

  const signingIn = $derived(connection.status === 'pairing' || connection.status === 'reauthorizing');
</script>

<AccountSettingsLayout
  {account}
  active="integrations"
  title="Sign in to Telegram"
  description="Connect your Telegram account so the residents you choose can read the chats it syncs.">
  <FlashMessages flash={$page.props.flash} />

  <div class="max-w-2xl space-y-4" data-testid="telegram-sign-in-page">
    {#if connection.status === 'connected'}
      <section class="space-y-3 rounded-lg border bg-muted/30 p-4" data-testid="telegram-sign-in-done">
        <p class="text-sm font-medium">Connected{connection.identity ? ` as ${connection.identity}` : ''}.</p>
        <p class="text-sm text-muted-foreground">
          Chats start syncing now. Choose which residents can read them on the Integrations page.
        </p>
        <Button href={integrations_url} size="sm">Back to Integrations</Button>
      </section>
    {:else if signingIn}
      <ConnectionTelegramLogin {connection} {account} />
      <p class="text-sm text-muted-foreground">
        This sign-in is also on the <a class="underline" href={integrations_url}>Integrations page</a>.
      </p>
    {:else}
      <section class="space-y-3 rounded-lg border bg-muted/30 p-4">
        <p class="text-sm">This Telegram connection is not signing in.</p>
        <Button href={integrations_url} variant="outline" size="sm">Back to Integrations</Button>
      </section>
    {/if}
  </div>
</AccountSettingsLayout>
