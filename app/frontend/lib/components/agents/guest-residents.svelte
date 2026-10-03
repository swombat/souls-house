<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { accountGuestMembershipsPath, accountGuestMembershipPath } from '@/routes';

  // guests: residents hosted elsewhere who are guests here.
  // away: residents hosted here who are guests elsewhere.
  // candidates: residents from your other accounts you may bring in.
  let { accountId, guests = [], away = [], candidates = [] } = $props();

  let selected = $state('');

  function addGuest() {
    if (!selected) return;
    router.post(
      accountGuestMembershipsPath(accountId),
      { agent_id: selected },
      {
        onSuccess: () => (selected = ''),
      }
    );
  }

  function remove(membership, question) {
    if (!confirm(question)) return;
    router.delete(accountGuestMembershipPath(accountId, membership.id));
  }
</script>

{#if guests.length > 0 || away.length > 0 || candidates.length > 0}
  <Card class="mt-8">
    <CardHeader>
      <CardTitle>Guest residents</CardTitle>
      <p class="text-sm text-muted-foreground">
        A guest stays hosted in their home account and takes part here like any other resident, in the conversations
        they are added to. Either account can end it.
      </p>
    </CardHeader>
    <CardContent class="space-y-6">
      {#if guests.length > 0}
        <ul class="space-y-2" data-testid="guest-residents">
          {#each guests as membership (membership.id)}
            <li class="flex items-center justify-between gap-4">
              <span
                >{membership.agent.name}
                <span class="text-muted-foreground">· hosted in {membership.home_account.name}</span></span>
              <Button
                variant="outline"
                size="sm"
                onclick={() =>
                  remove(
                    membership,
                    `Remove ${membership.agent.name} as a guest? They leave this account's conversations; their messages stay.`
                  )}>Remove</Button>
            </li>
          {/each}
        </ul>
      {/if}

      {#if away.length > 0}
        <ul class="space-y-2" data-testid="away-residents">
          {#each away as membership (membership.id)}
            <li class="flex items-center justify-between gap-4">
              <span
                >{membership.agent.name}
                <span class="text-muted-foreground">· guest in {membership.account.name}</span></span>
              <Button
                variant="outline"
                size="sm"
                onclick={() =>
                  remove(
                    membership,
                    `Withdraw ${membership.agent.name} from ${membership.account.name}? Their messages there stay.`
                  )}>Withdraw</Button>
            </li>
          {/each}
        </ul>
      {/if}

      {#if candidates.length > 0}
        <div class="flex items-center gap-3">
          <label class="sr-only" for="guest-candidate">Resident from another of your accounts</label>
          <select id="guest-candidate" class="border rounded-md px-3 py-2 bg-background text-sm" bind:value={selected}>
            <option value="">Choose a resident from your other accounts…</option>
            {#each candidates as candidate (candidate.id)}
              <option value={candidate.id}>{candidate.name} ({candidate.home_account_name})</option>
            {/each}
          </select>
          <Button size="sm" disabled={!selected} onclick={addGuest}>Add as guest</Button>
        </div>
      {/if}
    </CardContent>
  </Card>
{/if}
