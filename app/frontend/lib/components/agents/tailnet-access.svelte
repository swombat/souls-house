<!--
  A resident's Tailscale node on its integrations tab: the sign-in link while
  it waits to join, then the machines it can reach and the key to authorise.
-->
<script>
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { url, agentName } = $props();

  let report = $state(null);
  let busy = $state(false);
  let failed = $state(null);
  let copied = $state(false);
  let timer = null;
  let polls = 0;
  let wasWaiting = false;

  const MAX_POLLS = 200; // about 13 minutes at 4s

  const running = $derived(report?.available && report.backend_state === 'Running');
  const waitingForSignIn = $derived(report?.available && report.backend_state === 'NeedsLogin' && report.auth_url);

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || '';
  }

  async function request(method) {
    const response = await fetch(url, {
      method,
      headers: { Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
      credentials: 'same-origin',
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error || `Request failed (${response.status})`);
    return body;
  }

  async function refresh() {
    try {
      report = await request('GET');
      failed = null;
    } catch (error) {
      failed = error.message;
    }
    // When a sign-in completes, ask once more so the resident's SSH aliases
    // are written straight away rather than at its next boot.
    if (wasWaiting && report?.backend_state === 'Running') {
      wasWaiting = false;
      await bringUp();
      return;
    }
    wasWaiting = report?.backend_state === 'NeedsLogin';
    schedule();
  }

  function schedule() {
    clearTimeout(timer);
    const keepWatching = !report?.available || report.backend_state !== 'Running';
    if (keepWatching && polls < MAX_POLLS) {
      polls += 1;
      timer = setTimeout(refresh, 4000);
    }
  }

  async function bringUp() {
    busy = true;
    try {
      report = await request('POST');
      failed = null;
      wasWaiting = report?.backend_state === 'NeedsLogin';
      polls = 0;
      schedule();
    } catch (error) {
      failed = error.message;
    } finally {
      busy = false;
    }
  }

  async function copyKey() {
    await navigator.clipboard.writeText(report.pubkey);
    copied = true;
    setTimeout(() => (copied = false), 2000);
  }

  onMount(() => {
    refresh();
    return () => clearTimeout(timer);
  });
</script>

<div class="space-y-3 rounded-md border bg-muted/30 p-4 text-sm" data-testid="tailnet-access">
  {#if !report && !failed}
    <p class="text-muted-foreground">Checking {agentName}'s Tailscale node…</p>
  {:else if failed}
    <p class="text-destructive">{failed}</p>
  {:else if !report.available}
    <p class="text-muted-foreground">
      {#if report.provisioning_status === 'pending'}
        {agentName} picks up Tailscale access when its container next restarts, usually within a few minutes.
      {:else}
        {agentName}'s node isn't reachable right now: {report.error}
      {/if}
    </p>
  {:else if running}
    <p>
      <span class="font-medium">On your tailnet</span> as <code>{report.node}</code>.
      {#if report.hosts.length > 0}
        {agentName} can reach:
      {:else}
        It can't see any other machines yet.
      {/if}
    </p>
    {#if report.hosts.length > 0}
      <ul class="space-y-1">
        {#each report.hosts as host}
          <li class="flex items-center gap-2">
            <span
              class={host.online ? 'size-2 rounded-full bg-emerald-500' : 'size-2 rounded-full bg-muted-foreground/40'}
            ></span>
            <code>ssh {host.alias}</code>
            <span class="text-xs text-muted-foreground"
              >{host.os || ''}{host.online === false ? ' · offline' : ''}</span>
          </li>
        {/each}
      </ul>
    {/if}
    <p class="text-xs text-muted-foreground">
      So it never needs signing in again: in the
      <a
        href={report.admin_url}
        target="_blank"
        rel="noopener noreferrer"
        class="text-primary underline underline-offset-4">Tailscale Machines page</a
      >, find <code>{(report.node || '').split('.')[0]}</code>, open its menu on the right and choose
      <span class="font-medium">Disable Key Expiry</span>.
    </p>
  {:else if waitingForSignIn}
    <p>Sign in to Tailscale to put {agentName} on your tailnet.</p>
    <div class="flex flex-wrap items-center gap-3">
      <Button href={report.auth_url} target="_blank" rel="noopener noreferrer">Sign in to Tailscale</Button>
      <span class="text-xs text-muted-foreground">Waiting for sign-in…</span>
    </div>
  {:else}
    <p>{agentName} isn't on your tailnet yet.</p>
    <Button type="button" disabled={busy} onclick={bringUp}
      >{busy ? 'Getting a sign-in link…' : 'Connect to Tailscale'}</Button>
  {/if}

  {#if report?.available && report.pubkey}
    <details class="text-xs" open={running}>
      <summary class="cursor-pointer text-muted-foreground">{agentName}'s SSH key</summary>
      <p class="mt-2 text-muted-foreground">
        Add this line to <code>~/.ssh/authorized_keys</code> on each machine {agentName} should log in to (on a Mac, also
        turn on Remote Login).
      </p>
      <div class="mt-2 flex items-start gap-2">
        <code class="block flex-1 break-all rounded bg-background p-2">{report.pubkey}</code>
        <Button type="button" size="sm" variant="outline" onclick={copyKey}>{copied ? 'Copied' : 'Copy'}</Button>
      </div>
    </details>
  {/if}
</div>
