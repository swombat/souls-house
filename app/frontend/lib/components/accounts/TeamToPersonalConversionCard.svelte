<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import Alert from '$lib/components/Alert.svelte';
  import InfoCard from '$lib/components/InfoCard.svelte';
  import ConversionBenefitList from '$lib/components/accounts/ConversionBenefitList.svelte';
  import { UserCircle } from 'phosphor-svelte';

  let { canBePersonal = false, membersCount = 0, isConverting = false, onConvert, onCancel } = $props();

  const benefits = [
    {
      title: 'Single user only',
      description: 'The account will be limited to just you',
    },
    {
      title: 'No team management',
      description: 'Team features like invitations and roles will be disabled',
    },
    {
      title: 'Account name changes',
      description: 'The account will be renamed after its remaining owner, using their name or email address',
    },
  ];
</script>

<InfoCard title="Convert to Personal Account" icon="UserCircle">
  {#if canBePersonal}
    <div class="space-y-6">
      <ConversionBenefitList title="What happens when you convert to a personal account:" {benefits} />

      <Alert type="notice" title="Important Information">
        <ul class="list-disc list-inside space-y-1 text-sm">
          <li>You can convert back to a team account at any time</li>
          <li>All existing data will be preserved</li>
          <li>This action is reversible</li>
        </ul>
      </Alert>

      <div class="flex gap-3 mt-6">
        <Button onclick={onConvert} disabled={isConverting} class="gap-2">
          <UserCircle class="h-4 w-4" />
          {isConverting ? 'Converting...' : 'Convert to Personal Account'}
        </Button>
        <Button variant="outline" onclick={onCancel}>Cancel</Button>
      </div>
    </div>
  {:else}
    <Alert type="error" title="Cannot Convert to Personal Account">
      <div class="space-y-3 mt-2">
        <p>
          This team account cannot be converted to a personal account because it has <strong
            >{membersCount} memberships, including pending invitations</strong
          >.
        </p>
        <p>Personal accounts can only have one user. To convert this account:</p>
        <ol class="list-decimal list-inside space-y-1 ml-2">
          <li>Remove all other team members</li>
          <li>Ensure you're the only remaining member</li>
          <li>Then try converting again</li>
        </ol>
      </div>
    </Alert>

    <div class="flex gap-3 mt-6">
      <Button variant="outline" onclick={onCancel}>Go Back</Button>
    </div>
  {/if}
</InfoCard>
