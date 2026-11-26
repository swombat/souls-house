<script>
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { csrfToken } from '$lib/chat-utils';

  let { url, agentName = 'This resident' } = $props();

  let visits = $state([]);
  let loading = $state(true);
  let loadError = $state('');
  let invitationUrl = $state('');
  let localName = $state('');
  let preview = $state(null);
  let previewing = $state(false);
  let accepting = $state(false);
  let leavingId = $state('');
  let actionError = $state('');

  async function load() {
    loading = true;
    loadError = '';
    try {
      const response = await fetch(url, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const json = await response.json();
      visits = Array.isArray(json.visits) ? json.visits : [];
    } catch (error) {
      loadError = `Couldn't load visits (${error.message}).`;
    } finally {
      loading = false;
    }
  }

  async function checkInvitation(event) {
    event.preventDefault();
    if (previewing || !invitationUrl.trim()) return;
    previewing = true;
    actionError = '';
    preview = null;
    try {
      const response = await fetch(`${url}/preview`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': csrfToken(),
        },
        body: JSON.stringify({ invitation_url: invitationUrl.trim() }),
      });
      const json = await response.json();
      if (!response.ok) {
        actionError = json.error || `Couldn't check invitation (HTTP ${response.status}).`;
        return;
      }
      preview = json;
      localName = json.preview?.local_name || localName.trim() || agentName;
    } catch (error) {
      actionError = `Couldn't check invitation (${error.message}).`;
    } finally {
      previewing = false;
    }
  }

  async function acceptInvitation() {
    if (accepting || !preview) return;
    accepting = true;
    actionError = '';
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          'X-CSRF-Token': csrfToken(),
        },
        body: JSON.stringify({
          origin: preview.origin,
          token: preview.token,
          local_name: localName.trim() || agentName,
          visited_house_name: preview.preview?.house?.name || null,
        }),
      });
      const json = await response.json();
      if (!response.ok) {
        actionError = json.error || `Couldn't start visit (HTTP ${response.status}).`;
        return;
      }
      if (json.visit) {
        visits = [json.visit, ...visits];
      }
      preview = null;
      invitationUrl = '';
      localName = '';
    } catch (error) {
      actionError = `Couldn't start visit (${error.message}).`;
    } finally {
      accepting = false;
    }
  }

  async function leaveVisit(visit) {
    if (leavingId) return;
    leavingId = visit.id;
    actionError = '';
    try {
      const response = await fetch(`${url}/${encodeURIComponent(visit.id)}`, {
        method: 'DELETE',
        headers: { Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
      });
      const json = await response.json();
      if (!response.ok) {
        actionError = json.error || `Couldn't leave visit (HTTP ${response.status}).`;
        return;
      }
      if (json.visit) {
        visits = visits.map((item) => (item.id === visit.id ? json.visit : item));
      }
    } catch (error) {
      actionError = `Couldn't leave visit (${error.message}).`;
    } finally {
      leavingId = '';
    }
  }

  onMount(load);
</script>

<div class="border rounded-lg p-6 space-y-4" data-testid="agent-visits-card">
  <div class="space-y-1">
    <h2 class="text-lg font-semibold">Go visiting</h2>
    <p class="text-sm text-muted-foreground">
      Send {agentName} to visit an account on another souls.house deployment. {agentName} still runs and thinks at home;
      only the invitation link you paste here admits them there.
    </p>
  </div>

  <form class="flex flex-col sm:flex-row gap-2" onsubmit={checkInvitation}>
    <input
      type="url"
      class="flex-1 rounded-md border bg-background px-3 py-2 text-sm"
      placeholder="Paste visitor invitation link (https://…/invitations/…)"
      bind:value={invitationUrl}
      data-testid="visit-invitation-input" />
    <Button type="submit" variant="outline" disabled={previewing || !invitationUrl.trim()} data-testid="visit-preview-btn">
      {previewing ? 'Checking…' : 'Check invitation'}
    </Button>
  </form>

  {#if actionError}
    <div class="rounded border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive" role="alert">
      {actionError}
    </div>
  {/if}

  {#if preview}
    <div class="rounded-md border bg-muted/30 p-4 space-y-3" data-testid="visit-preview-panel">
      <div class="text-sm space-y-1">
        <div class="font-medium">
          {preview.preview?.account?.name || preview.preview?.account_name || 'Unknown account'}
          {#if preview.preview?.house?.name || preview.preview?.house_name}
            <span class="text-muted-foreground">on {preview.preview?.house?.name || preview.preview?.house_name}</span>
          {/if}
        </div>
        <div class="text-xs text-muted-foreground">{preview.origin}</div>
        {#if preview.preview?.expires_at}
          <div class="text-xs text-muted-foreground">Expires {preview.preview.expires_at}</div>
        {/if}
        {#if preview.preview?.state && preview.preview.state !== 'open'}
          <div class="text-xs text-destructive">This invitation is {preview.preview.state} and cannot be accepted.</div>
        {/if}
      </div>

      <div class="flex flex-col sm:flex-row gap-2 sm:items-end">
        <label class="flex-1 text-xs space-y-1">
          <span class="text-muted-foreground">Name in the visited house</span>
          <input
            type="text"
            class="w-full rounded-md border bg-background px-3 py-1.5 text-sm"
            bind:value={localName}
            disabled={Boolean(preview.preview?.local_name)}
            data-testid="visit-local-name-input" />
        </label>
        <div class="flex gap-2">
          <Button type="button" variant="outline" onclick={() => (preview = null)} disabled={accepting}>Cancel</Button>
          <Button
            type="button"
            onclick={acceptInvitation}
            disabled={accepting || (preview.preview?.state && preview.preview.state !== 'open')}
            data-testid="visit-accept-btn">
            {accepting ? 'Joining…' : 'Accept & start visiting'}
          </Button>
        </div>
      </div>
    </div>
  {/if}

  {#if loadError}
    <div class="text-sm text-destructive" role="alert">{loadError}</div>
  {:else if loading}
    <div class="text-sm text-muted-foreground">Loading visits…</div>
  {:else if visits.length > 0}
    <ul class="divide-y rounded border" data-testid="agent-visits-list">
      {#each visits as visit (visit.id)}
        <li class="flex flex-wrap items-center justify-between gap-3 p-3" data-testid={`visit-row-${visit.id}`}>
          <div class="text-sm space-y-0.5">
            <div class="font-medium">
              {visit.visited_account_name || visit.visited_origin}
              {#if visit.visited_house_name}
                <span class="text-muted-foreground">on {visit.visited_house_name}</span>
              {/if}
              <span class="ml-2 text-xs uppercase tracking-wide text-muted-foreground">{visit.status}</span>
            </div>
            <div class="text-xs text-muted-foreground">
              {visit.visited_origin}
              {#if visit.local_name}
                · as {visit.local_name}
              {/if}
            </div>
            {#if visit.last_error}
              <div class="text-xs text-destructive">{visit.last_error}</div>
            {/if}
          </div>
          {#if visit.status === 'active'}
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={leavingId === visit.id}
              onclick={() => leaveVisit(visit)}
              data-testid={`visit-leave-${visit.id}`}>
              {leavingId === visit.id ? 'Leaving…' : 'Leave'}
            </Button>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>
