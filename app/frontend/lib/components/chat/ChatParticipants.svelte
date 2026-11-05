<script>
  import { router } from '@inertiajs/svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Users, UserMinus } from 'phosphor-svelte';
  import { accountChatParticipantPath } from '@/routes';

  let { chat, account, agents = [], onerror } = $props();
  let removing = $state(null);
  let open = $state(false);

  function remove(agent) {
    if (removing || !agent.can_remove_from_chat) return;
    open = false;
    if (
      !confirm(
        `Remove ${agent.name} from this conversation? Past messages stay. Future “Ask all” requests and queued handoffs will no longer reach them. This does not remove them from the account.`
      )
    )
      return;

    removing = agent.id;
    router.delete(accountChatParticipantPath(account.id, chat.id), {
      data: { agent_id: agent.id },
      preserveScroll: true,
      onError: () => onerror?.('Could not remove this resident. Please try again.'),
      onFinish: () => (removing = null),
    });
  }
</script>

{#if agents.some((agent) => agent.can_remove_from_chat)}
  <DropdownMenu.Root bind:open>
    <DropdownMenu.Trigger
      aria-label="Conversation residents"
      class="inline-flex items-center justify-center gap-1 h-8 rounded-md px-2 text-sm hover:bg-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
      <Users size={18} />
      <span class="hidden sm:inline">Residents</span>
    </DropdownMenu.Trigger>
    <DropdownMenu.Content align="end" class="w-64">
      <DropdownMenu.Label>In this conversation</DropdownMenu.Label>
      {#each agents as agent (agent.id)}
        {#if agent.can_remove_from_chat}
          <DropdownMenu.Item disabled={removing !== null} onclick={() => remove(agent)}>
            <UserMinus size={16} class="mr-2 shrink-0" />
            <span class="truncate">Remove {agent.name}</span>
          </DropdownMenu.Item>
        {:else}
          <DropdownMenu.Item disabled>{agent.name}</DropdownMenu.Item>
        {/if}
      {/each}
      <DropdownMenu.Separator />
      <p class="px-2 py-1.5 text-xs text-muted-foreground">
        Past messages stay. A responding resident must finish before removal.
      </p>
    </DropdownMenu.Content>
  </DropdownMenu.Root>
{/if}
