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
  import ResidentHandoffCapCard from '$lib/components/accounts/ResidentHandoffCapCard.svelte';
  import ReflexesCard from '$lib/components/accounts/ReflexesCard.svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { createAccountSettingDraft } from '$lib/account-setting-draft.svelte.js';

  let {
    account,
    can_be_personal,
    members = [],
    can_manage = false,
    can_invite_owner = false,
    current_user_id,
    resident_handoff_cap = 6,
    reflexes_enabled = false,
    reflexes_site_scope = 'account_choice',
  } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`Account:${account.id}`]: [
        'account',
        'members',
        'can_be_personal',
        'can_manage',
        'can_invite_owner',
        'resident_handoff_cap',
        'reflexes_enabled',
      ],
    });
  });

  let showInviteForm = $state(false);
  const nameDraft = createAccountSettingDraft(
    () => account.id,
    () => account.name
  );
  const nameChanged = $derived(nameDraft.value.trim() !== '' && nameDraft.value.trim() !== account.name);

  function formatDate(dateString) {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  }

  function saveName(event) {
    event.preventDefault();
    if (!nameChanged || nameDraft.saving) return;

    nameDraft.save(
      (value, options) => router.put(accountPath(account.id), { account: { name: value.trim() } }, options),
      (response) => response.props.account.name
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

  let inviteAccount = account.id;
  $effect(() => {
    if (inviteAccount !== account.id) {
      inviteAccount = account.id;
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
          <Input id="account-name" bind:value={nameDraft.value} required />
        </div>
        <Button type="submit" disabled={!nameChanged || nameDraft.saving}
          >{nameDraft.saving ? 'Saving…' : 'Save name'}</Button>
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

  <ResidentHandoffCapCard accountId={account.id} cap={resident_handoff_cap} canManage={can_manage} />

  <ReflexesCard
    accountId={account.id}
    enabled={reflexes_enabled}
    canManage={can_manage}
    siteScope={reflexes_site_scope} />

  <AccountTypeCard
    {account}
    canBePersonal={can_be_personal}
    membersCount={members.length || 1}
    onConvert={goToConvertConfirmation} />

  {#if !account.personal}
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
