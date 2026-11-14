<script>
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { csrfToken } from '$lib/chat-utils';

  // Which Chaos hooks this resident's runs are held to (jaMBVj). A storage
  // move once dropped a resident's wake hook and nothing noticed; now each
  // run is checked, and a run missing an expected hook gets the yellow mark.
  // The owner can hold an event expected, or turn it off when a hook was
  // removed on purpose. Ids and status only, never a command or its output.
  let { url, agentName = 'This resident' } = $props();

  let data = $state(null);
  let loadError = $state('');
  let saveError = $state('');
  let saving = $state('');

  async function load() {
    loadError = '';
    try {
      const response = await fetch(url, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      data = await response.json();
    } catch (error) {
      loadError = `Couldn't load the hook settings (${error.message}).`;
    }
  }

  async function setState(event, state) {
    saving = event;
    saveError = '';
    try {
      const response = await fetch(url, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
        body: JSON.stringify({ event, state }),
      });
      const json = await response.json();
      if (!response.ok) {
        saveError = json.error || `Couldn't save (HTTP ${response.status}).`;
        return;
      }
      data = json;
    } catch (error) {
      saveError = `Couldn't save (${error.message}).`;
    } finally {
      saving = '';
    }
  }

  const SOURCES = { observed: 'seen on a run', owner: 'set by you', resident: `set by ${agentName}` };

  function describe(entry) {
    if (!entry?.state) return 'Not set: no warning until a run sees a working hook for it.';
    const how = SOURCES[entry.source] || entry.source;
    const when = entry.at
      ? new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(entry.at))
      : null;
    const head = entry.state === 'off' ? 'Off: removed on purpose, no warning.' : 'Expected: a run without it is marked.';
    return `${head} ${how}${when ? `, ${when}` : ''}.`;
  }

  function hookStatus(hook) {
    if (hook.inactive_reason) return hook.inactive_reason;
    if (!hook.enabled) return 'disabled';
    if (!hook.approved) return 'not approved';
    return 'active';
  }

  let latestHooks = $derived(Array.isArray(data?.latest_run?.hooks?.hooks) ? data.latest_run.hooks.hooks : null);

  onMount(load);
</script>

{#if loadError}
  <div class="border rounded-lg p-6 text-sm text-destructive" role="alert">{loadError}</div>
{:else if data}
  <div class="border rounded-lg p-6 space-y-4" data-testid="hook-expectations-card">
    <div class="space-y-1">
      <h2 class="text-lg font-semibold">Chaos hooks</h2>
      <p class="text-sm text-muted-foreground">
        Hooks are what {agentName}'s runtime runs at set moments, such as the wake at the start of a session. If one goes
        missing, the resident often can't tell from the inside. Each run is checked against what is expected here, and a run
        that lacks an expected hook gets a yellow mark in its conversation. Only ids and status are recorded, never what a
        hook runs or prints.
      </p>
    </div>

    <ul class="divide-y rounded border">
      {#each data.events as event (event)}
        {@const entry = data.hook_expectations?.[event]}
        <li class="flex flex-wrap items-center justify-between gap-3 p-3" data-testid={`hook-expectation-${event}`}>
          <div class="text-sm">
            <div class="font-medium">{data.labels?.[event] || event}</div>
            <div class="text-muted-foreground">{describe(entry)}</div>
          </div>
          <div class="flex gap-2">
            {#each data.states as state (state)}
              <Button
                type="button"
                size="sm"
                variant={entry?.state === state ? 'default' : 'outline'}
                disabled={saving === event || entry?.state === state}
                aria-pressed={entry?.state === state}
                data-testid={`hook-expectation-${event}-${state}`}
                onclick={() => setState(event, state)}>
                {state === 'off' ? 'Off' : 'Expected'}
              </Button>
            {/each}
          </div>
        </li>
      {/each}
    </ul>

    {#if saveError}
      <p class="text-sm text-destructive" role="alert">{saveError}</p>
    {/if}

    {#if data.latest_run}
      <div class="space-y-2 text-sm">
        <div class="font-medium">Latest run</div>
        {#if data.latest_run.hook_warning}
          <p class="text-amber-700 dark:text-amber-400" data-testid="hook-expectations-warning">
            {data.latest_run.hook_warning}
          </p>
        {/if}
        {#if latestHooks === null}
          <p class="text-muted-foreground">This run didn't report its hooks (the runtime may not have the update yet).</p>
        {:else if latestHooks.length === 0}
          <p class="text-muted-foreground">This run found no hooks configured.</p>
        {:else}
          <ul class="space-y-1" data-testid="hook-expectations-latest">
            {#each latestHooks as hook (hook.id)}
              <li class="flex justify-between gap-3">
                <span class="font-mono text-xs break-all">{hook.id}</span>
                <span class="text-muted-foreground whitespace-nowrap">{hook.event} · {hookStatus(hook)}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </div>
    {/if}
  </div>
{/if}
