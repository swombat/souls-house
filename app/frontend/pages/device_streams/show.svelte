<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import DeviceStreamsFrame from '$lib/components/device-streams/DeviceStreamsFrame.svelte';
  import { ArrowLeft, Check, Copy, Key, Trash } from 'phosphor-svelte';

  let {
    account = null,
    stream,
    can_configure: canConfigure = false,
    users = [],
    agents = [],
    credentials = [],
    sessions = [],
    urls,
  } = $props();

  let readerUserIds = $state(users.filter((user) => user.reader).map((user) => user.id));
  let readerAgentIds = $state(agents.filter((agent) => agent.reader).map((agent) => agent.id));
  let enabled = $state(stream.enabled);
  let saving = $state(false);
  let sessionUuid = $state('');

  function toggle(list, id, checked) {
    return checked ? [...new Set([...list, id])] : list.filter((existing) => existing !== id);
  }

  function saveReaders(event) {
    event.preventDefault();
    saving = true;
    router.patch(
      urls.controls,
      { reader_user_ids: readerUserIds, reader_agent_ids: readerAgentIds, enabled: enabled ? '1' : '0' },
      { preserveScroll: true, onFinish: () => (saving = false) }
    );
  }

  // The raw token lives only in this component's state. It is fetched as JSON,
  // never passed as page props, so it is not kept in browser history.
  let issued = $state(null);
  let issuing = $state(false);
  let issueError = $state(null);
  let copied = $state(false);

  async function issueCredential() {
    issuing = true;
    issueError = null;
    try {
      const response = await fetch(urls.credential, {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        },
        credentials: 'same-origin',
        cache: 'no-store',
      });
      if (!response.ok) throw new Error((await response.text()) || `HTTP ${response.status}`);
      issued = await response.json();
      router.reload({ only: ['credentials'], preserveScroll: true });
    } catch (error) {
      issueError = error.message;
    } finally {
      issuing = false;
    }
  }

  async function copyToken() {
    await navigator.clipboard.writeText(issued.token);
    copied = true;
    setTimeout(() => (copied = false), 2000);
  }

  function dismissToken() {
    issued = null;
  }

  // Precaution for real browsers' back/forward cache: never keep the token in a
  // document that may be frozen and restored.
  function forgetToken() {
    issued = null;
  }

  function revoke(credential) {
    if (!confirm('Revoke this device? It will no longer be able to send readings.')) return;
    router.delete(credential.revoke_url, { preserveScroll: true });
  }

  function eraseSession(session) {
    if (!confirm('Delete this session? Every reader and device stops seeing it.')) return;
    router.delete(session.erase_url, { preserveScroll: true });
  }

  function eraseByUuid(event) {
    event.preventDefault();
    const uuid = sessionUuid.trim();
    if (!uuid || !confirm(`Delete session ${uuid}?`)) return;
    router.delete(`${urls.erase_session}?session_id=${encodeURIComponent(uuid)}`, {
      preserveScroll: true,
      onSuccess: () => (sessionUuid = ''),
    });
  }

  function eraseAll() {
    if (!confirm('Delete all sessions and close this stream? You cannot reopen it.')) return;
    router.delete(urls.controls);
  }

  const formatDate = (iso) => new Date(iso).toLocaleString();
</script>

<svelte:window onpagehide={forgetToken} onpageshow={(event) => event.persisted && forgetToken()} />

<svelte:head><title>{stream.name} · Device stream</title></svelte:head>

<DeviceStreamsFrame {account} title={stream.name} description={`Device stream in ${stream.account_name}`}>
  <div class="max-w-3xl space-y-6">
    <a href={urls.index} class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
      <ArrowLeft size={16} /> Your streams
    </a>

    <section class="rounded-2xl border bg-card p-5 sm:p-6 space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        {#if stream.erased}
          <Badge variant="outline">Deleted and closed</Badge>
        {:else if stream.enabled}
          <Badge>Ingesting</Badge>
        {:else}
          <Badge variant="secondary">Ingestion disabled</Badge>
        {/if}
        <span class="text-sm text-muted-foreground"
          >Account: <strong class="text-foreground">{stream.account_name}</strong></span>
      </div>
      <p class="text-sm">
        Stream key: <code class="rounded bg-muted px-1.5 py-0.5 font-mono text-xs break-all">{stream.stream_key}</code>
      </p>
      {#if !account}
        <p class="text-sm text-muted-foreground">
          Personal recovery controls: you may revoke devices or delete data here. Reader changes and new credentials
          require account membership.
          {#if urls.manage_in_account}
            <a href={urls.manage_in_account} class="underline underline-offset-4 hover:text-foreground"
              >Manage in account</a>
          {/if}
        </p>
      {/if}
      <p class="text-sm text-muted-foreground">
        Readers may analyse RR data; this does not authorize publication. As everywhere in this house, deleting hides
        data, it does not destroy it: deleted sessions disappear from every reader and device, but the samples stay
        stored on the server and in its backups. Mac files, downloaded copies and derived findings are not affected.
        Infrastructure administrators can access stored data. If you need data truly gone, run your own house.
      </p>
    </section>

    {#if stream.erased}
      <p class="rounded-xl border border-dashed p-5 text-sm text-muted-foreground">
        This stream is deleted and closed. It cannot ingest again.
      </p>
    {:else}
      {#if canConfigure}
        <section class="rounded-2xl border bg-card p-5 sm:p-6">
          <form onsubmit={saveReaders} class="space-y-5">
            <fieldset class="min-w-0 space-y-3">
              <legend class="text-lg font-semibold">Readers</legend>
              <p class="text-sm text-muted-foreground">
                Explicit selection. Future house members are not added automatically.
              </p>
              <div class="grid gap-2 sm:grid-cols-2 [&>*]:min-w-0">
                {#each users as user (user.id)}
                  <label class="flex min-w-0 items-center gap-2 rounded-lg border px-3 py-2 text-sm hover:bg-muted/50">
                    <input
                      type="checkbox"
                      name="reader_user_ids[]"
                      value={user.id}
                      class="size-4 accent-primary"
                      checked={readerUserIds.includes(user.id)}
                      onchange={(event) =>
                        (readerUserIds = toggle(readerUserIds, user.id, event.currentTarget.checked))} />
                    <span class="min-w-0 truncate" title={user.name}>{user.name}</span>
                  </label>
                {/each}
                {#each agents as agent (agent.id)}
                  <label class="flex min-w-0 items-center gap-2 rounded-lg border px-3 py-2 text-sm hover:bg-muted/50">
                    <input
                      type="checkbox"
                      name="reader_agent_ids[]"
                      value={agent.id}
                      class="size-4 accent-primary"
                      checked={readerAgentIds.includes(agent.id)}
                      onchange={(event) =>
                        (readerAgentIds = toggle(readerAgentIds, agent.id, event.currentTarget.checked))} />
                    <span class="min-w-0 truncate">{agent.name}</span>
                    <span class="ml-auto shrink-0 text-xs text-muted-foreground">resident</span>
                  </label>
                {/each}
              </div>
            </fieldset>
            <label class="flex items-center gap-2 text-sm font-medium">
              <input type="checkbox" name="enabled" value="1" class="size-4 accent-primary" bind:checked={enabled} />
              Enable device ingestion
            </label>
            <Button type="submit" disabled={saving}>Save readers and ingestion choice</Button>
          </form>
        </section>
      {/if}

      <section class="rounded-2xl border bg-card p-5 sm:p-6 space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-lg font-semibold">Devices</h2>
          {#if urls.credential}
            <Button variant="outline" size="sm" onclick={issueCredential} disabled={issuing}>
              <Key /> Create append-only device credential
            </Button>
          {/if}
        </div>
        {#if issueError}
          <p class="text-sm text-destructive">Could not create a credential: {issueError}</p>
        {/if}
        {#if issued}
          <div class="space-y-3 rounded-xl border border-primary/40 bg-primary/5 p-4" data-testid="issued-credential">
            <p class="text-sm font-medium">Copy once to your device. It will not be shown again.</p>
            <p class="text-sm text-muted-foreground">
              Append-only to this stream. Do not paste it into chat. It cannot read data or act as a resident.
            </p>
            <div class="flex items-start gap-2">
              <pre
                class="flex-1 overflow-x-auto rounded-lg bg-muted p-3 font-mono text-xs break-all whitespace-pre-wrap">{issued.token}</pre>
              <Button variant="outline" size="icon" onclick={copyToken} aria-label="Copy credential">
                {#if copied}<Check />{:else}<Copy />{/if}
              </Button>
            </div>
            <p class="text-sm">
              POST JSON to <code class="rounded bg-muted px-1.5 py-0.5 font-mono text-xs break-all"
                >{issued.endpoint}</code>
              with this token as the Bearer credential.
            </p>
            <Button size="sm" onclick={dismissToken}>I've copied it</Button>
          </div>
        {/if}
        {#if credentials.length === 0}
          <p class="text-sm text-muted-foreground">No device credentials yet.</p>
        {:else}
          <ul class="divide-y rounded-xl border">
            {#each credentials as credential (credential.id)}
              <li class="flex items-center justify-between gap-3 px-4 py-3 text-sm">
                <span>Created {formatDate(credential.created_at)}</span>
                {#if credential.revoked}
                  <Badge variant="outline">Revoked</Badge>
                {:else}
                  <Button variant="outline" size="sm" onclick={() => revoke(credential)}>Revoke device</Button>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
      </section>

      <section class="rounded-2xl border bg-card p-5 sm:p-6 space-y-4">
        <h2 class="text-lg font-semibold">
          Sessions <span class="text-sm font-normal text-muted-foreground">(newest 100)</span>
        </h2>
        {#if sessions.length === 0}
          <p class="text-sm text-muted-foreground">No sessions recorded yet.</p>
        {:else}
          <ul class="divide-y rounded-xl border">
            {#each sessions as session (session.uuid)}
              <li class="flex items-center justify-between gap-3 px-4 py-3 text-sm">
                <span class="min-w-0">
                  <code class="font-mono text-xs break-all">{session.uuid}</code>
                  <span class="block text-xs text-muted-foreground">{formatDate(session.created_at)}</span>
                </span>
                {#if session.erased}
                  <Badge variant="outline">Deleted</Badge>
                {:else}
                  <Button variant="ghost" size="sm" onclick={() => eraseSession(session)}><Trash /> Delete</Button>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
        <form onsubmit={eraseByUuid} class="flex flex-col sm:flex-row sm:items-end gap-3 border-t pt-4">
          <div class="flex-1 space-y-1.5">
            <Label for="session-uuid">Delete an older session by UUID</Label>
            <Input
              id="session-uuid"
              bind:value={sessionUuid}
              required
              placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" />
          </div>
          <Button type="submit" variant="outline">Delete session</Button>
        </form>
      </section>

      <section class="rounded-2xl border border-destructive/40 bg-destructive/5 p-5 sm:p-6 space-y-3">
        <h2 class="text-lg font-semibold">Delete all and close</h2>
        <p class="text-sm text-muted-foreground">
          This hides every session from every reader and revokes every device. The samples stay stored. You cannot
          reopen this stream.
        </p>
        <Button
          variant="outline"
          class="border-destructive text-destructive hover:bg-destructive/10 hover:text-destructive"
          onclick={eraseAll}>Delete all sessions and close stream</Button>
      </section>
    {/if}
  </div>
</DeviceStreamsFrame>
