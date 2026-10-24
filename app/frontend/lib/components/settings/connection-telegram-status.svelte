<script>
  import { router } from '@inertiajs/svelte';
  import { availabilityMessage } from '$lib/telegram-connection';

  let { connection, account } = $props();

  const comms = $derived(connection.comms || {});
  const notice = $derived(availabilityMessage(comms.availability));

  function setSearchAll(value) {
    router.patch(`/accounts/${account.id}/service_connections/${connection.id}`, {
      service_connection: { search_all_dialogs: value },
    });
  }
</script>

<section class="space-y-3" data-testid="telegram-status">
  <dl class="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
    <dt class="text-muted-foreground">Signed in as</dt>
    <dd class="min-w-0 break-words font-medium">{connection.identity || 'Unknown Telegram account'}</dd>
    <dt class="text-muted-foreground">Chats</dt>
    <dd>{comms.synced_chats ?? 0} of {comms.chats ?? 0} chats synced</dd>
  </dl>
  {#if notice}
    <div
      class="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100"
      role="status">
      <p>{notice}</p>
      {#if comms.availability?.reason}
        <p class="mt-1 break-words text-amber-800 dark:text-amber-200">Reason: {comms.availability.reason}</p>
      {/if}
    </div>
  {/if}
  {#if connection.can_delegate}
    <label class="flex items-start gap-2 text-sm">
      <input
        type="checkbox"
        class="mt-0.5"
        checked={comms.search_all_dialogs === true}
        onchange={(event) => setSearchAll(event.currentTarget.checked)} />
      <span>
        Let residents search beyond the synced chats
        <span class="block text-muted-foreground">
          Searches then reach every chat in this Telegram account, including channels and large groups.
        </span>
      </span>
    </label>
  {/if}
</section>
