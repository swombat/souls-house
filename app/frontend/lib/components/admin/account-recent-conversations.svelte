<script>
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  let { usage } = $props();
  function dateTime(value) {
    return value ? new Date(value).toLocaleString() : 'Never';
  }
</script>

<Card>
  <CardHeader
    ><CardTitle>Last 10 conversations</CardTitle><CardDescription
      >Most recently updated account conversations. Counts do not expose message contents. Failures are historical;
      latest attempts below show their own timestamps.</CardDescription
    ></CardHeader>
  <CardContent class="overflow-x-auto">
    <Table>
      <TableHeader
        ><TableRow
          ><TableHead>Conversation</TableHead><TableHead>Residents</TableHead><TableHead>Messages & tokens</TableHead
          ><TableHead>Response diagnostics</TableHead><TableHead>Updated</TableHead></TableRow
        ></TableHeader>
      <TableBody>
        {#each usage.recent_conversations as chat}
          <TableRow
            ><TableCell
              ><div class="font-medium">{chat.title}</div>
              <div class="text-xs text-muted-foreground">
                {chat.id}{chat.discarded ? ' · Deleted' : chat.archived ? ' · Archived' : ''}
              </div></TableCell
            ><TableCell>{chat.agents.join(', ') || 'No residents'}</TableCell><TableCell>
              <div>{chat.messages} messages · {chat.resident_replies} resident replies</div>
              <div class="text-xs text-muted-foreground">
                Recent peak input: {chat.context_tokens?.toLocaleString() ?? '—'} tokens
              </div>
              <div class="text-xs text-muted-foreground">
                Message tokens: {chat.message_tokens?.input?.toLocaleString() ?? '—'} in / {chat.message_tokens?.output?.toLocaleString() ??
                  '—'} out
              </div>
              <div class="text-xs text-muted-foreground">
                Runtime tokens: {chat.runtime_tokens?.input?.toLocaleString() ?? '—'} in / {chat.runtime_tokens?.output?.toLocaleString() ??
                  '—'} out
              </div>
              <div class="text-xs text-muted-foreground">
                Recorded totals; may be partial. Sources overlap—do not add.
              </div>
            </TableCell><TableCell>
              <div>
                {chat.response_attempts} attempts ·
                <span class:text-destructive={chat.failed_attempts > 0}
                  >{chat.failed_attempts} failed (historical)</span>
              </div>
              {#each chat.latest_responses ?? [] as response}
                <div class="mt-2 text-xs">
                  <a
                    class="underline"
                    href={`/admin/agents/${response.agent_id}/runtime?${new URLSearchParams({ session_id: response.session_id, from: new Date(new Date(response.started_at).getTime() - 60000).toISOString(), to: new Date(new Date(response.finished_at || response.started_at).getTime() + 60000).toISOString() })}`}
                    >{response.agent_name}</a
                  >:
                  <span class:text-destructive={response.status === 'failed'}>{response.status}</span>
                  · {response.auth_mode === 'oauth_account' ? 'OAuth' : 'API key'}
                  {#if response.transport_status != null}
                    · HTTP {response.transport_status}{/if}
                  {#if response.returncode != null}
                    · exit {response.returncode}{/if}
                  <div class="text-muted-foreground">Latest attempt: {dateTime(response.started_at)}</div>
                  {#if response.finished_at}<div class="text-muted-foreground">
                      Finished: {dateTime(response.finished_at)}
                    </div>{/if}
                </div>
              {:else}<div class="text-xs text-muted-foreground">No recorded conversation attempts.</div>{/each}
              <div class="mt-1 text-xs text-muted-foreground">
                Completed runs do not necessarily post a reply. Wakes and orientation are excluded.
              </div>
            </TableCell>
            ><TableCell>{dateTime(chat.updated_at)}</TableCell></TableRow>
        {:else}<TableRow
            ><TableCell colspan={5} class="text-muted-foreground">No conversations yet.</TableCell></TableRow
          >{/each}
      </TableBody>
    </Table>
  </CardContent>
</Card>
