<script>
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import { Badge } from '$lib/components/shadcn/badge';
  let { account } = $props();
  const usage = $derived(account.usage);
</script>

<Card>
  <CardHeader
    ><CardTitle>Integrations & AI access</CardTitle><CardDescription
      >Connection metadata only—no tokens, keys or external content. An enabled grant may still be pending provisioning.</CardDescription
    ></CardHeader>
  <CardContent class="space-y-5">
    <div class="flex flex-wrap gap-2">
      {#each usage.ai_providers.filter((provider) => provider.configured) as provider}<Badge variant="secondary"
          >{provider.provider} API key configured</Badge>
      {:else}<p class="text-sm text-muted-foreground">No account AI API keys configured.</p>{/each}
      <Badge variant="outline">Shared AI fallback {account.use_system_ai_credentials ? 'enabled' : 'disabled'}</Badge>
    </div>
    <p class="text-xs text-muted-foreground">
      Resident subscription authentication and Telegram bots are shown under each resident above.
    </p>
    <div class="overflow-x-auto">
      <Table>
        <TableHeader
          ><TableRow
            ><TableHead>Connection</TableHead><TableHead>Status</TableHead><TableHead>Scope</TableHead><TableHead
              >Resident access enabled</TableHead
            ></TableRow
          ></TableHeader>
        <TableBody>
          {#each usage.integrations as integration}
            <TableRow>
              <TableCell
                ><div class="font-medium">{integration.label}</div>
                <div class="text-xs text-muted-foreground">{integration.provider}</div></TableCell>
              <TableCell
                ><Badge variant={integration.status === 'connected' ? 'secondary' : 'outline'}
                  >{integration.status}</Badge
                ></TableCell>
              <TableCell
                >{integration.scope.replaceAll('_', ' ')}{#if integration.enabled_for_new_agents}<div
                    class="text-xs text-muted-foreground">
                    Default for new residents
                  </div>{/if}</TableCell>
              <TableCell>{integration.agents.join(', ') || 'None / account-level'}</TableCell>
            </TableRow>
          {:else}<TableRow
              ><TableCell colspan={4} class="text-muted-foreground"
                >No account service integrations configured.</TableCell
              ></TableRow
            >{/each}
        </TableBody>
      </Table>
    </div>
  </CardContent>
</Card>
