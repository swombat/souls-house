<script>
  import { page } from '@inertiajs/svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ConnectionWhatsappPairing from '$lib/components/settings/connection-whatsapp-pairing.svelte';
  import { Button } from '$lib/components/shadcn/button';

  // The focused page Connect WhatsApp opens: the same pairing as the
  // Integrations card (phone number code or QR), on its own so that on a
  // phone it is the whole screen, then a clear way back once it is linked.
  // The codes come only from the pairing endpoint, by fetch, never props.
  let { account, connection, integrations_url } = $props();

  const linking = $derived(['pairing', 'reauthorizing', 'error'].includes(connection.status));
</script>

<AccountSettingsLayout
  {account}
  active="integrations"
  title="Link WhatsApp"
  description="Link your WhatsApp account so the residents you choose can read the chats it syncs.">
  <FlashMessages flash={$page.props.flash} />

  <div class="max-w-2xl space-y-4" data-testid="whatsapp-link-page">
    {#if connection.status === 'connected'}
      <section class="space-y-3 rounded-lg border bg-muted/30 p-4" data-testid="whatsapp-link-done">
        <p class="text-sm font-medium">Linked{connection.identity ? ` as ${connection.identity}` : ''}.</p>
        <p class="text-sm text-muted-foreground">
          Chats start syncing now. Choose which residents can read them on the Integrations page.
        </p>
        <Button href={integrations_url} size="sm">Back to Integrations</Button>
      </section>
    {:else if linking}
      <ConnectionWhatsappPairing {connection} {account} />
      <p class="text-sm text-muted-foreground">
        This pairing is also on the <a class="underline" href={integrations_url}>Integrations page</a>.
      </p>
    {:else}
      <section class="space-y-3 rounded-lg border bg-muted/30 p-4">
        <p class="text-sm">This WhatsApp connection is not waiting to be linked.</p>
        <Button href={integrations_url} variant="outline" size="sm">Back to Integrations</Button>
      </section>
    {/if}
  </div>
</AccountSettingsLayout>
