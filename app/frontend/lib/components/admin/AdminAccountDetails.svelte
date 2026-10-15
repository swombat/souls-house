<script>
  import AccountMemberships from './account-memberships.svelte';
  import { router } from '@inertiajs/svelte';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Switch } from '$lib/components/shadcn/switch/index.js';
  import InfoCard from '$lib/components/InfoCard.svelte';
  import Avatar from '$lib/components/Avatar.svelte';
  import AdminAccountUsage from './AdminAccountUsage.svelte';
  import AdminXPostingCard from './AdminXPostingCard.svelte';

  let { account, formatDate } = $props();
  let teamName = $state(account.name || '');
  const members = $derived(account.memberships || []);
  $effect(() => {
    teamName = account.name || '';
  });

  function toggleDisabled() {
    const action = account.disabled ? 'enable' : 'disable';
    const label = account.disabled ? 'enable' : 'disable';
    if (!confirm(`Are you sure you want to ${label} ${account.name}?`)) return;

    router.patch(`/admin/accounts/${account.id}/${action}`);
  }

  function convertToTeam() {
    router.patch(`/admin/accounts/${account.id}/convert`, {
      account_type: 'team',
      account: { name: teamName },
    });
  }

  function convertToPersonal() {
    if (!confirm(`Convert ${account.name} to a personal account? This requires exactly one member.`)) return;

    router.patch(`/admin/accounts/${account.id}/convert`, { account_type: 'personal' });
  }

  function setFounding(enabled) {
    router.patch(`/admin/accounts/${account.id}/founding`, { account: { founding: enabled } });
  }

  function setFieldSwarm(enabled) {
    router.patch(`/admin/accounts/${account.id}/field_swarm`, { account: { field_swarm_enabled: enabled } });
  }

  function setTweetsHouseKey(enabled) {
    router.patch(`/admin/accounts/${account.id}/field_tweets_house_key`, {
      account: { field_tweets_house_key: enabled },
    });
  }

  function dollars(value) {
    return value == null ? '—' : `$${Number(value).toFixed(4)}`;
  }

  const swarmRows = $derived(
    account.field_swarm
      ? [
          ['This account, 30 days', account.field_swarm.account_30_days],
          ['This account, all time', account.field_swarm.account_all_time],
          ['All accounts, 30 days', account.field_swarm.house_30_days],
          ['All accounts, all time', account.field_swarm.house_all_time],
        ]
      : []
  );

  function setSharedAiCredentials(enabled) {
    router.patch(`/admin/accounts/${account.id}/shared_ai_credentials`, {
      account: { use_system_ai_credentials: enabled },
    });
  }
</script>

<div class="p-4 sm:p-8 [overflow-wrap:anywhere]">
  <div class="mb-8 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
    <div class="min-w-0">
      <h1 class="text-3xl font-bold mb-2">{account.name}</h1>
      <div class="flex flex-wrap gap-2 text-sm text-muted-foreground">
        <Badge variant="outline">
          {account.account_type === 'personal' ? 'Personal Account' : 'Organization'}
        </Badge>
        {#if account.disabled}
          <Badge variant="destructive">Disabled</Badge>
        {:else}
          <Badge variant="secondary">Enabled</Badge>
        {/if}
      </div>
    </div>

    <Button variant={account.disabled ? 'default' : 'destructive'} onclick={toggleDisabled}>
      {account.disabled ? 'Enable Account' : 'Disable Account'}
    </Button>
  </div>

  {#if account.usage}
    <AdminAccountUsage {account} />
  {/if}

  <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
    <InfoCard title="Account Information" icon="Info">
      <dl class="space-y-3">
        <div>
          <dt class="text-sm text-muted-foreground">Account ID</dt>
          <dd class="font-mono text-sm">{account.id}</dd>
        </div>
        <div>
          <dt class="text-sm text-muted-foreground">Type</dt>
          <dd>{account.account_type === 'personal' ? 'Personal' : 'Organization'}</dd>
        </div>
        {#if account.owner}
          <div>
            <dt class="text-sm text-muted-foreground">Owner</dt>
            <dd>
              <div class="flex items-center gap-2">
                <Avatar user={account.owner} size="small" />
                <div>
                  {account.owner.name || account.owner.email_address}
                  {#if account.owner.name}
                    <div class="text-sm text-muted-foreground">{account.owner.email_address}</div>
                  {/if}
                </div>
              </div>
            </dd>
          </div>
        {/if}
      </dl>
    </InfoCard>

    <InfoCard title="Statistics" icon="ChartBar">
      <dl class="space-y-3">
        <div>
          <dt class="text-sm text-muted-foreground">Total Users</dt>
          <dd class="text-2xl font-bold">{account.users_count || 0}</dd>
        </div>
        <div>
          <dt class="text-sm text-muted-foreground">Created</dt>
          <dd>{formatDate(account.created_at)}</dd>
        </div>
        <div>
          <dt class="text-sm text-muted-foreground">Last Updated</dt>
          <dd>{formatDate(account.updated_at)}</dd>
        </div>
      </dl>
    </InfoCard>
  </div>

  <Card class="mb-8">
    <CardHeader>
      <CardTitle>Account Type</CardTitle>
      <CardDescription>Convert this account between personal and team modes.</CardDescription>
    </CardHeader>
    <CardContent>
      {#if account.account_type === 'personal'}
        <div class="flex flex-col gap-3 md:flex-row md:items-end">
          <label class="flex-1 text-sm font-medium">
            Team name
            <input
              class="mt-1 flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              bind:value={teamName} />
          </label>
          <Button onclick={convertToTeam}>Convert to Team</Button>
        </div>
      {:else}
        <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <p class="text-sm text-muted-foreground">
            Team accounts can become personal accounts only when exactly one membership remains.
          </p>
          <Button onclick={convertToPersonal} disabled={members.length !== 1}>Convert to Personal</Button>
        </div>
      {/if}
    </CardContent>
  </Card>

  <Card class="mb-8">
    <CardHeader>
      <CardTitle>Shared AI credentials</CardTitle>
      <CardDescription>
        Allow this account to use the application's Rails credential keys when it has no provider-specific key.
      </CardDescription>
    </CardHeader>
    <CardContent>
      <div class="flex items-center justify-between gap-6 rounded-md border p-4">
        <div class="space-y-1">
          <Label for={`shared-ai-credentials-${account.id}`}>Use shared keys as fallback</Label>
          <p class="text-sm text-muted-foreground">
            New accounts start with this disabled. Account owners cannot change it themselves.
          </p>
        </div>
        <Switch
          id={`shared-ai-credentials-${account.id}`}
          aria-label="Use shared keys as fallback"
          checked={account.use_system_ai_credentials}
          onCheckedChange={setSharedAiCredentials} />
      </div>
      <div class="mt-3 flex items-center justify-between gap-6 rounded-md border p-4">
        <div class="space-y-1">
          <Label for={`founding-${account.id}`}>Founding or family account</Label>
          <p class="text-sm text-muted-foreground">
            Kept out of growth numbers on the site dashboard and costed as its own band.
          </p>
        </div>
        <Switch
          id={`founding-${account.id}`}
          aria-label="Founding or family account"
          checked={account.founding}
          onCheckedChange={setFounding} />
      </div>
    </CardContent>
  </Card>

  <Card class="mb-8">
    <CardHeader>
      <CardTitle>Tweet streams</CardTitle>
      <CardDescription>
        Accounts pay for their tweet streams with their own TwitterAPI.io integration. Turn this on to let this account
        use the house's key instead while it has none, within the house ceilings in Settings.
      </CardDescription>
    </CardHeader>
    <CardContent>
      <div class="flex items-center justify-between gap-6 rounded-md border p-4">
        <div class="space-y-1">
          <Label for={`field-tweets-house-key-${account.id}`}>Use the house TwitterAPI.io key</Label>
          <p class="text-sm text-muted-foreground">
            {account.field_tweets_own_integration
              ? 'This account has its own integration, which pays first.'
              : 'This account has no integration of its own.'}
          </p>
        </div>
        <Switch
          id={`field-tweets-house-key-${account.id}`}
          aria-label="Use the house TwitterAPI.io key"
          checked={account.field_tweets_house_key}
          onCheckedChange={setTweetsHouseKey} />
      </div>
    </CardContent>
  </Card>

  <AdminXPostingCard {account} />

  <Card class="mb-8">
    <CardHeader>
      <CardTitle>Field swarm search</CardTitle>
      <CardDescription>
        A test feature: residents ask one question of every item carrying a tag, one Claude Haiku reader per item, paid
        by the house. Off for every account until turned on here.
      </CardDescription>
    </CardHeader>
    <CardContent>
      <div class="flex items-center justify-between gap-6 rounded-md border p-4">
        <div class="space-y-1">
          <Label for={`field-swarm-${account.id}`}>Allow field swarm search</Label>
          <p class="text-sm text-muted-foreground">
            On for {account.field_swarm?.enabled_accounts ?? 0} account(s). Every search and reader call is recorded with
            its reported cost.
          </p>
        </div>
        <Switch
          id={`field-swarm-${account.id}`}
          aria-label="Allow field swarm search"
          checked={account.field_swarm_enabled}
          onCheckedChange={setFieldSwarm} />
      </div>
      <div class="mt-3 overflow-x-auto">
        <table class="w-full text-sm">
          <thead class="text-left text-muted-foreground">
            <tr>
              <th class="py-1 pr-4 font-normal"></th>
              <th class="py-1 pr-4 font-normal">Searches</th>
              <th class="py-1 pr-4 font-normal">Reads</th>
              <th class="py-1 pr-4 font-normal">Cost</th>
              <th class="py-1 pr-4 font-normal">Per search</th>
              <th class="py-1 pr-4 font-normal">Per read</th>
              <th class="py-1 font-normal">Cost unknown</th>
            </tr>
          </thead>
          <tbody>
            {#each swarmRows as [label, row] (label)}
              <tr class="border-t">
                <td class="py-1 pr-4">{label}</td>
                <td class="py-1 pr-4">{row.searches}</td>
                <td class="py-1 pr-4">{row.reads}</td>
                <td class="py-1 pr-4">{dollars(row.cost_usd)}</td>
                <td class="py-1 pr-4">{dollars(row.cost_per_search_usd)}</td>
                <td class="py-1 pr-4">{dollars(row.cost_per_read_usd)}</td>
                <td class="py-1">{row.uncertain_cost_reads}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </CardContent>
  </Card>

  <AccountMemberships {account} {formatDate} />
</div>
