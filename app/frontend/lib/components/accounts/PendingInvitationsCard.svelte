<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import Avatar from '$lib/components/Avatar.svelte';
  import { Envelope, Trash } from 'phosphor-svelte';

  let { invitations = [], canManage = false, formatDate, onResendInvitation, onRemoveMember } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle class="text-lg flex items-center gap-2 mb-2">
      <Envelope class="h-5 w-5" />
      Pending Invitations ({invitations.length})
    </CardTitle>
  </CardHeader>
  <CardContent>
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Email</TableHead>
          <TableHead>Role</TableHead>
          <TableHead>Invited By</TableHead>
          <TableHead>Invited On</TableHead>
          {#if canManage}
            <TableHead>Actions</TableHead>
          {/if}
        </TableRow>
      </TableHeader>
      <TableBody>
        {#each invitations as member (member.id)}
          <TableRow>
            <TableCell>{member.user.email_address}</TableCell>
            <TableCell>
              <Badge variant="outline">{member.role}</Badge>
            </TableCell>
            <TableCell>
              <div class="flex items-center gap-2">
                {#if member.invited_by}
                  <Avatar user={member.invited_by} size="small" />
                  <span>{member.invited_by.full_name}</span>
                {:else}
                  <span>System</span>
                {/if}
              </div>
            </TableCell>
            <TableCell class="text-muted-foreground">
              {formatDate(member.invited_at)}
            </TableCell>
            {#if canManage}
              <TableCell>
                <div class="flex items-center gap-2">
                  <Button variant="ghost" size="sm" onclick={() => onResendInvitation(member)}>
                    <Envelope class="h-4 w-4" />
                    Resend
                  </Button>
                  {#if member.can_remove}
                    <Button
                      variant="ghost"
                      size="sm"
                      onclick={() => onRemoveMember(member)}
                      class="text-destructive hover:text-destructive opacity-30 hover:opacity-100">
                      <Trash class="h-4 w-4" />
                      Cancel
                    </Button>
                  {/if}
                </div>
              </TableCell>
            {/if}
          </TableRow>
        {/each}
      </TableBody>
    </Table>
  </CardContent>
</Card>
