<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Card from '$lib/components/shadcn/card';
  import { editAccountPath } from '@/routes';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import PendingInvitationsCard from '$lib/components/accounts/PendingInvitationsCard.svelte';
  import TeamMembersCard from '$lib/components/accounts/TeamMembersCard.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { createDynamicSync } from '$lib/use-sync';

  let { account, members = [], can_manage = false, can_invite_owner = false, current_user_id } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`Account:${account.id}`]: ['account', 'members', 'can_manage', 'can_invite_owner'],
    });
  });

  let showInviteForm = $state(false);
  let inviteAccount = account.id;
  $effect(() => {
    if (inviteAccount !== account.id) {
      inviteAccount = account.id;
      showInviteForm = false;
    }
  });

  function formatDate(dateString) {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  }

  function goToConvertConfirmation() {
    router.visit(editAccountPath(account.id) + '?convert=true');
  }

  function removeMember(member) {
    if (confirm(`Remove ${member.display_name} from ${account.name}?`)) {
      router.delete(`/accounts/${account.id}/members/${member.id}`);
    }
  }

  function resendInvitation(member) {
    router.post(`/accounts/${account.id}/invitations/${member.id}/resend`);
  }

  function handleInvite(event) {
    const { email, role } = event.detail;
    router.post(`/accounts/${account.id}/invitations`, { email, role });
    showInviteForm = false;
  }

  const pendingInvitations = $derived(members.filter((m) => m.invitation_pending));
  const activeMembers = $derived(members.filter((m) => !m.invitation_pending));
</script>

<svelte:head>
  <title>Users · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="users"
  title="Users"
  description="Manage who belongs to this account and pending invitations.">
  <FlashMessages flash={$page.props.flash} />

  {#if account.personal}
    <Card.Root>
      <Card.Header>
        <Card.Title>Personal account</Card.Title>
        <Card.Description>Only you belong to this account, so nobody else can be invited.</Card.Description>
      </Card.Header>
      <Card.Content class="space-y-4">
        <p class="text-sm text-muted-foreground">
          To invite other people to share this account's residents, keys and settings, convert it to a team account.
        </p>
        <Button onclick={goToConvertConfirmation} variant="outline">Convert to team account</Button>
      </Card.Content>
    </Card.Root>
  {:else}
    <TeamMembersCard
      members={activeMembers}
      canManage={can_manage}
      canInviteOwner={can_invite_owner}
      currentUserId={current_user_id}
      bind:showInviteForm
      {formatDate}
      onInvite={handleInvite}
      onRemoveMember={removeMember} />

    {#if pendingInvitations.length > 0}
      <PendingInvitationsCard
        invitations={pendingInvitations}
        canManage={can_manage}
        {formatDate}
        onResendInvitation={resendInvitation}
        onRemoveMember={removeMember} />
    {/if}
  {/if}
</AccountSettingsLayout>
