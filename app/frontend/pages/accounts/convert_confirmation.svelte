<script>
  import { page, router } from '@inertiajs/svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import PersonalToTeamConversionCard from '$lib/components/accounts/PersonalToTeamConversionCard.svelte';
  import TeamToPersonalConversionCard from '$lib/components/accounts/TeamToPersonalConversionCard.svelte';
  import { accountPath } from '@/routes';

  const { account, can_be_personal, members_count } = $page.props;

  let isConverting = $state(false);
  let teamName = $state('');
  let teamNameError = $state('');

  function validateTeamName() {
    if (!teamName.trim()) {
      teamNameError = 'Team name is required';
      return false;
    }
    if (teamName.trim().length < 2) {
      teamNameError = 'Team name must be at least 2 characters';
      return false;
    }
    teamNameError = '';
    return true;
  }

  function handleConversion() {
    if (account.personal) {
      // Converting to team - validate name first
      if (!validateTeamName()) {
        return;
      }

      isConverting = true;
      router.patch(
        `/accounts/${account.id}`,
        {
          convert_to: 'team',
          account: { name: teamName.trim() },
        },
        {
          onFinish: () => {
            isConverting = false;
          },
        }
      );
    } else {
      // Converting to personal
      isConverting = true;
      router.patch(
        `/accounts/${account.id}`,
        {
          convert_to: 'personal',
        },
        {
          onFinish: () => {
            isConverting = false;
          },
        }
      );
    }
  }

  function goBack() {
    router.visit(accountPath(account.id));
  }

  // Clear error when typing
  $effect(() => {
    if (teamName) {
      teamNameError = '';
    }
  });
</script>

<AccountSettingsLayout
  {account}
  active="general"
  title="Change account type"
  description={account.personal
    ? 'Convert this personal account to a team account.'
    : 'Convert this team account to a personal account.'}>
  {#if account.personal}
    <PersonalToTeamConversionCard
      bind:teamName
      {teamNameError}
      {isConverting}
      onConvert={handleConversion}
      onCancel={goBack} />
  {:else}
    <TeamToPersonalConversionCard
      canBePersonal={can_be_personal}
      membersCount={members_count}
      {isConverting}
      onConvert={handleConversion}
      onCancel={goBack} />
  {/if}
</AccountSettingsLayout>
