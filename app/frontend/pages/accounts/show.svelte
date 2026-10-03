<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Card from '$lib/components/shadcn/card';
  import { accountPath, editAccountPath } from '@/routes';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import AccountTypeCard from '$lib/components/accounts/AccountTypeCard.svelte';
  import PendingInvitationsCard from '$lib/components/accounts/PendingInvitationsCard.svelte';
  import TeamMembersCard from '$lib/components/accounts/TeamMembersCard.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { useSync } from '$lib/use-sync';

  let { account, can_be_personal, members = [], can_manage = false, current_user_id } = $props();

  // Subscribe to real-time updates for this account and its members
  useSync({
    [`Account:${account.id}`]: ['account', 'members'],
  });

  let showInviteForm = $state(false);
  let accountName = $state(account.name || '');
  let savingName = $state(false);
  const nameChanged = $derived(accountName.trim() !== '' && accountName.trim() !== account.name);

  function formatDate(dateString) {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  }

  function saveName(event) {
    event.preventDefault();
    if (!nameChanged || savingName) return;

    savingName = true;
    router.put(
      accountPath(account.id),
      { account: { name: accountName.trim() } },
      { preserveScroll: true, onFinish: () => (savingName = false) }
    );
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

  $effect(() => {
    // Close invite form on successful submission or error
    if ($page.props.flash?.success || $page.props.flash?.errors) {
      showInviteForm = false;
    }
  });

  const pendingInvitations = $derived(members.filter((m) => m.invitation_pending));
  const activeMembers = $derived(members.filter((m) => !m.invitation_pending));
</script>

<svelte:head>
  <title>Account settings · {account.name}</title>
</svelte:head>

<AccountSettingsLayout {account} active="general" title="Account Settings">
  <FlashMessages flash={$page.props.flash} />

  <Card.Root>
    <Card.Header>
      <Card.Title>Name</Card.Title>
      <Card.Description>Shown in the account switcher and to everyone in the account.</Card.Description>
    </Card.Header>
    <Card.Content>
      <form class="flex flex-col gap-3 sm:flex-row sm:items-end" onsubmit={saveName}>
        <div class="flex-1 space-y-2">
          <Label for="account-name">Account name</Label>
          <Input id="account-name" bind:value={accountName} required />
        </div>
        <Button type="submit" disabled={!nameChanged || savingName}>{savingName ? 'Saving…' : 'Save name'}</Button>
      </form>
      <dl class="mt-4 flex flex-wrap gap-x-8 gap-y-1 text-xs text-muted-foreground">
        <div class="flex gap-1">
          <dt>Created</dt>
          <dd>{formatDate(account.created_at)}</dd>
        </div>
        <div class="flex gap-1">
          <dt>Account ID</dt>
          <dd class="font-mono">{account.id}</dd>
        </div>
      </dl>
    </Card.Content>
  </Card.Root>

  <AccountTypeCard
    {account}
    canBePersonal={can_be_personal}
    membersCount={members.length || 1}
    onConvert={goToConvertConfirmation} />

  {#if !account.personal}
    <TeamMembersCard
      members={activeMembers}
      canManage={can_manage}
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
