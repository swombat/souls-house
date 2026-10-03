<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import Alert from '$lib/components/Alert.svelte';
  import InfoCard from '$lib/components/InfoCard.svelte';
  import ConversionBenefitList from '$lib/components/accounts/ConversionBenefitList.svelte';
  import { Users } from 'phosphor-svelte';

  let { teamName = $bindable(''), teamNameError = '', isConverting = false, onConvert, onCancel } = $props();

  const benefits = [
    {
      title: 'Invite team members',
      description: "You'll be able to invite other users to collaborate on your account",
    },
    {
      title: 'Assign roles',
      description: 'Control access with owner, admin, and member roles',
    },
    {
      title: 'Choose a team name',
      description: 'Choose the name people will see for this shared account',
    },
  ];
</script>

<InfoCard title="Convert to Team Account" icon="Users">
  <div class="space-y-6">
    <ConversionBenefitList title="What happens when you convert to a team account:" {benefits} />

    <Alert type="notice" title="Important Information">
      <ul class="list-disc list-inside space-y-1 text-sm">
        <li>You can convert back to a personal account only when you're the sole member</li>
        <li>All existing data and settings will be preserved</li>
        <li>You'll become the owner of the team account</li>
      </ul>
    </Alert>

    <div class="space-y-4 mt-6">
      <div class="space-y-2">
        <Label for="team-name">Team Name <span class="text-destructive">*</span></Label>
        <Input
          id="team-name"
          type="text"
          bind:value={teamName}
          placeholder="Enter your team name"
          class={teamNameError ? 'border-destructive' : ''}
          disabled={isConverting}
          onkeydown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault();
              onConvert();
            }
          }} />
        {#if teamNameError}
          <p class="text-sm text-destructive">{teamNameError}</p>
        {/if}
      </div>

      <div class="flex gap-3 mt-6">
        <Button onclick={onConvert} disabled={isConverting || !teamName.trim()} class="gap-2">
          <Users class="h-4 w-4" />
          {isConverting ? 'Converting...' : 'Convert to Team Account'}
        </Button>
        <Button variant="outline" onclick={onCancel}>Cancel</Button>
      </div>
    </div>
  </div>
</InfoCard>
