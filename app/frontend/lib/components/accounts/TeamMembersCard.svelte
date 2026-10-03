<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import Avatar from '$lib/components/Avatar.svelte';
  import InviteMemberForm from '$lib/components/forms/InviteMemberForm.svelte';
  import { Trash, UserPlus, Users } from 'phosphor-svelte';

  let {
    members = [],
    canManage = false,
    currentUserId = null,
    showInviteForm = $bindable(false),
    formatDate,
    onInvite,
    onRemoveMember,
  } = $props();
</script>

<Card>
  <CardHeader class="mb-2">
    <div class="flex items-center justify-between">
      <CardTitle class="text-lg flex items-center gap-2">
        <Users class="h-5 w-5" />
        Team Members ({members.length})
      </CardTitle>
      {#if canManage}
        {#if showInviteForm}
          <Button onclick={() => (showInviteForm = false)} variant="outline" size="sm">Cancel</Button>
        {:else}
          <Button onclick={() => (showInviteForm = true)} size="sm" class="gap-2">
            <UserPlus class="h-4 w-4" />
            Invite Member
          </Button>
        {/if}
      {/if}
    </div>
  </CardHeader>
  <CardContent>
    {#if showInviteForm}
      <div class="mb-6 p-4 border rounded-lg bg-muted/50">
        <InviteMemberForm on:close={() => (showInviteForm = false)} on:invite={onInvite} />
      </div>
    {/if}

    {#if members.length > 0}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Name</TableHead>
            <TableHead class="hidden 2xl:table-cell">Email</TableHead>
            <TableHead>Role</TableHead>
            <TableHead class="hidden md:table-cell">Joined</TableHead>
            {#if canManage}
              <TableHead>Actions</TableHead>
            {/if}
          </TableRow>
        </TableHeader>
        <TableBody>
          {#each members as member (member.id)}
            <TableRow>
              <TableCell>
                <div class="flex items-center gap-2">
                  <Avatar user={member.user} size="small" />
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="font-medium">{member.display_name}</span>
                      {#if member.user_id === currentUserId}
                        <Badge variant="outline" class="text-xs">You</Badge>
                      {/if}
                    </div>
                    {#if member.display_name !== member.user.email_address}
                      <div class="text-xs text-muted-foreground 2xl:hidden">{member.user.email_address}</div>
                    {/if}
                  </div>
                </div>
              </TableCell>
              <TableCell class="hidden 2xl:table-cell">{member.user.email_address}</TableCell>
              <TableCell>
                <Badge
                  variant={member.role === 'owner' ? 'default' : member.role === 'admin' ? 'secondary' : 'outline'}>
                  {member.role}
                </Badge>
              </TableCell>
              <TableCell class="hidden md:table-cell text-muted-foreground">
                {member.confirmed_at ? formatDate(member.confirmed_at) : 'Not confirmed'}
              </TableCell>
              {#if canManage}
                <TableCell>
                  {#if member.can_remove}
                    <Button
                      variant="ghost"
                      size="sm"
                      onclick={() => onRemoveMember(member)}
                      class="text-destructive hover:text-destructive opacity-30 hover:opacity-100">
                      <Trash class="h-4 w-4" />
                      Remove
                    </Button>
                  {/if}
                </TableCell>
              {/if}
            </TableRow>
          {/each}
        </TableBody>
      </Table>
    {:else}
      <p class="p-8 text-center text-muted-foreground">
        You're the only member of this team account. Invite others to collaborate with you.
      </p>
    {/if}
  </CardContent>
</Card>
