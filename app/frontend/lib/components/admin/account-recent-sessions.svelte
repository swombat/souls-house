<script>
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  let { usage } = $props();
  function dateTime(value) {
    return value ? new Date(value).toLocaleString() : 'Never';
  }

  function sessionUrl(session) {
    const query = new URLSearchParams({
      session_id: session.session_id,
      from: new Date(new Date(session.last_at).getTime() - 24 * 60 * 60 * 1000).toISOString(),
      to: new Date(new Date(session.last_at).getTime() + 1000).toISOString(),
    });
    return `/admin/agents/${session.agent_id}/runtime?${query}`;
  }
</script>

<Card>
  <CardHeader
    ><CardTitle>Last 10 runtime sessions</CardTitle><CardDescription
      >Most recently active logical sessions, grouped per resident. A session can contain many trigger attempts. Open
      one to inspect its recent runtime detail.</CardDescription
    ></CardHeader>
  <CardContent class="overflow-x-auto">
    <Table>
      <TableHeader
        ><TableRow
          ><TableHead>Resident / session</TableHead><TableHead>First observed</TableHead><TableHead
            >Last active</TableHead
          ><TableHead>Attempts</TableHead></TableRow
        ></TableHeader>
      <TableBody>
        {#each usage.recent_sessions as session}
          <TableRow
            ><TableCell
              ><a class="text-primary underline underline-offset-4" href={sessionUrl(session)}>{session.agent_name}</a>
              <div class="max-w-56 truncate text-xs text-muted-foreground" title={session.session_id}>
                {session.session_id}
              </div></TableCell
            ><TableCell>{dateTime(session.first_at)}</TableCell><TableCell>{dateTime(session.last_at)}</TableCell
            ><TableCell>{session.runs}</TableCell></TableRow>
        {:else}<TableRow
            ><TableCell colspan={4} class="text-muted-foreground"
              >No runtime sessions recorded. Inline residents can have conversations without hosted runtime telemetry.</TableCell
            ></TableRow
          >{/each}
      </TableBody>
    </Table>
  </CardContent>
</Card>
