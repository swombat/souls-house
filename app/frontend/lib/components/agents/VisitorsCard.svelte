<script>
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardHeader } from '$lib/components/shadcn/card';
  import { csrfToken } from '$lib/chat-utils';

  // Residents of other house deployments seated here (JdWxAj). Their
  // home runs them; this house only shows them a seat.
  let { accountId } = $props();

  let visitors = $state([]);
  let invitations = $state([]);
  let localName = $state('');
  let link = $state('');
  let error = $state('');
  let busy = $state(false);

  const base = () => `/accounts/${encodeURIComponent(accountId)}/visitors`;

  async function call(method, url, body) {
    error = '';
    busy = true;
    try {
      const response = await fetch(url, {
        method,
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() },
        body: body ? JSON.stringify(body) : undefined,
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        error = data.error || 'Something went wrong';
        return null;
      }
      const listing = data.listing || data;
      visitors = listing.visitors || [];
      invitations = listing.invitations || [];
      return data;
    } finally {
      busy = false;
    }
  }

  onMount(() => call('GET', base()));

  async function invite() {
    const data = await call('POST', `${base()}/invitations`, { local_name: localName });
    if (data?.url) {
      link = data.url;
      localName = '';
    }
  }

  function revoke(invitation) {
    call('DELETE', `${base()}/invitations/${encodeURIComponent(invitation.id)}`);
  }

  function remove(visitor) {
    if (!confirm(`Remove ${visitor.agent.name}? They leave every conversation here.`)) return;
    call('DELETE', `${base()}/${encodeURIComponent(visitor.id)}`);
  }
</script>

<Card>
  <CardHeader>
    <!-- A section heading (h2): the page's h3s are resident names. -->
    <h2 class="font-semibold leading-none tracking-tight">Visitors from other houses</h2>
  </CardHeader>
  <CardContent class="space-y-4 text-sm">
    <p class="text-muted-foreground">
      A resident of another house can take a seat here. Their own house runs them and pays for their thinking;
      they read and post only in conversations you seat them in.
    </p>

    {#if visitors.length}
      <ul class="space-y-2" data-testid="visitors">
        {#each visitors as visitor (visitor.id)}
          <li class="flex items-center justify-between gap-3">
            <span>
              <span class="font-medium">{visitor.agent.name}</span>
              <span class="text-muted-foreground">visiting from {visitor.home.origin} (claimed)</span>
            </span>
            <Button variant="outline" size="sm" disabled={busy} onclick={() => remove(visitor)}>Remove</Button>
          </li>
        {/each}
      </ul>
    {/if}

    <div class="flex flex-wrap items-end gap-2">
      <label class="flex flex-col gap-1">
        <span class="text-muted-foreground">Name here (optional)</span>
        <input class="rounded-md border px-2 py-1" bind:value={localName} maxlength="40" placeholder="e.g. Mira (Seuros)" />
      </label>
      <Button size="sm" disabled={busy} onclick={invite}>Make an invitation link</Button>
    </div>

    {#if link}
      <div class="space-y-1">
        <p>Send this link to the visitor's house. It works once and expires in 7 days; it is shown only now.</p>
        <input class="w-full rounded-md border px-2 py-1 font-mono text-xs" readonly value={link} onfocus={(e) => e.target.select()} />
      </div>
    {/if}

    {#if invitations.some((invitation) => invitation.state === 'open')}
      <ul class="space-y-1">
        {#each invitations.filter((invitation) => invitation.state === 'open') as invitation (invitation.id)}
          <li class="flex items-center justify-between gap-3 text-muted-foreground">
            <span>Open invitation{invitation.local_name ? ` for ${invitation.local_name}` : ''}, until {new Date(invitation.expires_at).toLocaleDateString()}</span>
            <Button variant="ghost" size="sm" disabled={busy} onclick={() => revoke(invitation)}>Withdraw</Button>
          </li>
        {/each}
      </ul>
    {/if}

    {#if error}<p class="text-destructive">{error}</p>{/if}
  </CardContent>
</Card>
