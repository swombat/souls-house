<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { RadioGroup, RadioGroupItem } from '$lib/components/shadcn/radio-group';
  import Avatar from '$lib/components/Avatar.svelte';
  import { Trash } from 'phosphor-svelte';
  let { account, formatDate } = $props();
  let newMemberEmail = $state('');
  let newMemberRole = $state('member');
  const selectedAccountId = $derived(account.id);

  $effect(() => {
    // Live sync replaces account props; only switching accounts should discard
    // a membership draft. Successful submission clears it in onSuccess below.
    selectedAccountId;
    newMemberEmail = '';
    newMemberRole = 'member';
  });

  const members = $derived(account.memberships || []);

  function removeMember(member) {
    if (!confirm(`Remove ${member.email_address || member.user?.email_address} from ${account.name}?`)) return;

    router.delete(`/admin/accounts/${account.id}/memberships/${member.id}`);
  }

  function addMember(event) {
    event.preventDefault();
    if (!newMemberEmail) return;

    router.post(
      `/admin/accounts/${account.id}/memberships`,
      {
        membership: {
          email: newMemberEmail,
          role: newMemberRole,
        },
      },
      {
        onSuccess: () => {
          newMemberEmail = '';
          newMemberRole = 'member';
        },
      }
    );
  }
</script>

<Card>
  <CardHeader>
    <CardTitle class="mb-2">Users ({members.length})</CardTitle>
    <CardDescription>Add existing users to this account or remove current members.</CardDescription>
  </CardHeader>
  <CardContent class="space-y-6">
    <form onsubmit={addMember} class="rounded-lg border bg-muted/20 p-4">
      <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
        <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_auto]">
          <div class="space-y-2">
            <Label for={`admin-add-member-email-${account.id}`}>Existing user email</Label>
            <Input
              id={`admin-add-member-email-${account.id}`}
              type="email"
              placeholder="user@example.com"
              bind:value={newMemberEmail}
              disabled={account.account_type === 'personal'}
              required />
          </div>

          <div class="space-y-2">
            <Label>Role</Label>
            <RadioGroup
              bind:value={newMemberRole}
              class="flex flex-col gap-2 md:flex-row md:items-center md:gap-4"
              disabled={account.account_type === 'personal'}>
              <div class="flex items-center space-x-2">
                <RadioGroupItem value="member" id={`admin-add-member-role-member-${account.id}`} />
                <Label for={`admin-add-member-role-member-${account.id}`} class="font-normal cursor-pointer"
                  >Member</Label>
              </div>
              <div class="flex items-center space-x-2">
                <RadioGroupItem value="admin" id={`admin-add-member-role-admin-${account.id}`} />
                <Label for={`admin-add-member-role-admin-${account.id}`} class="font-normal cursor-pointer"
                  >Admin</Label>
              </div>
              <div class="flex items-center space-x-2">
                <RadioGroupItem value="owner" id={`admin-add-member-role-owner-${account.id}`} />
                <Label for={`admin-add-member-role-owner-${account.id}`} class="font-normal cursor-pointer"
                  >Owner</Label>
              </div>
            </RadioGroup>
          </div>
        </div>

        <Button type="submit" disabled={account.account_type === 'personal' || !newMemberEmail}>Add User</Button>
      </div>
      {#if account.account_type === 'personal'}
        <p class="mt-3 text-sm text-muted-foreground">Convert this account to a team before adding more users.</p>
      {/if}
    </form>

    {#if members.length > 0}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Name</TableHead>
            <TableHead>Email</TableHead>
            <TableHead>Role</TableHead>
            <TableHead>Status</TableHead>
            <TableHead>Joined</TableHead>
            <TableHead>Actions</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {#each members as member (member.id)}
            <TableRow class={member.confirmed ? '' : 'opacity-50'}>
              <TableCell>
                <div class="flex items-center gap-2">
                  <Avatar user={member.user} size="small" />
                  <span>{member.full_name || member.display_name || '-'}</span>
                </div>
              </TableCell>
              <TableCell>
                <div class="font-medium">{member.email_address || member.user?.email_address}</div>
              </TableCell>
              <TableCell>
                <Badge variant={member.role === 'owner' ? 'default' : 'secondary'}>
                  {member.role}
                </Badge>
              </TableCell>
              <TableCell class="capitalize">{member.status}</TableCell>
              <TableCell class="text-sm text-muted-foreground">
                {formatDate(member.created_at)}
              </TableCell>
              <TableCell>
                <Button
                  variant="ghost"
                  size="sm"
                  onclick={() => removeMember(member)}
                  disabled={member.role === 'owner' &&
                    members.filter((m) => m.role === 'owner' && m.confirmed).length === 1}
                  class="text-destructive hover:text-destructive opacity-60 hover:opacity-100">
                  <Trash class="h-4 w-4" />
                  Remove
                </Button>
              </TableCell>
            </TableRow>
          {/each}
        </TableBody>
      </Table>
    {:else}
      <p class="text-muted-foreground">No users in this account.</p>
    {/if}
  </CardContent>
</Card>
