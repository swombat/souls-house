<script>
  // The X posting row on Integrations. X is its own record (XIntegration),
  // not a service connection, so it has its own row: the handle, whether
  // posting is on, and a switch per resident. Connecting, the X app and the
  // account-wide switch stay on the X page.
  import { router } from '@inertiajs/svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  import CompactIntegrationHeader from './compact-integration-header.svelte';
  import { XLogo, CaretDown, UsersThree, WarningCircle, ArrowRight } from 'phosphor-svelte';

  let { x, compact = false, open = false, onToggle = () => {} } = $props();

  let updating = $state({});
  let granted = $derived(x.residents.filter((resident) => resident.enabled));
  let compactWarning = $derived(
    !x.connected
      ? 'Not connected'
      : x.enabled && !x.media_scope_granted
        ? 'Reconnect X to post media'
        : granted.length === 0
          ? 'No resident can post'
          : null
  );
  let summary = $derived(
    granted.length === 0 ? 'No resident can post' : `${granted.map((resident) => resident.name).join(', ')} can post`
  );
  let attention = $derived(
    !x.connected
      ? 'Not connected'
      : !x.enabled
        ? 'Posting is off'
        : !x.media_scope_granted
          ? 'Reconnect X to post media'
          : null
  );

  function toggleResident(resident, enabled) {
    updating = { ...updating, [resident.id]: true };
    router.patch(
      x.grant_url,
      { agent_id: resident.id, enabled },
      {
        preserveScroll: true,
        onFinish() {
          const next = { ...updating };
          delete next[resident.id];
          updating = next;
        },
      }
    );
  }
</script>

<div class="rounded-xl border bg-card" data-testid="x-posting-connection">
  {#if compact}
    <CompactIntegrationHeader
      title="X"
      detail={x.x_username ? `@${x.x_username}` : null}
      toggleName={x.x_username ? `X · @${x.x_username}` : 'X posting'}
      residents={granted}
      warning={compactWarning}
      {open}
      panelId="x-posting-panel"
      {onToggle}>
      {#snippet icon()}
        <span class="flex size-7 shrink-0 items-center justify-center rounded-md bg-black text-white">
          <XLogo size={16} weight="bold" />
        </span>
      {/snippet}
    </CompactIntegrationHeader>
  {:else}
    <button
      type="button"
      class="flex w-full items-start gap-3 px-4 py-4 text-left sm:px-6"
      aria-expanded={open}
      aria-controls="x-posting-panel"
      onclick={onToggle}>
      <span class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-black text-white">
        <XLogo size={22} weight="bold" />
      </span>
      <div class="min-w-0 flex-1 space-y-1">
        <div>
          <h3 class="font-semibold leading-snug">{x.x_username ? `@${x.x_username}` : 'X posting'}</h3>
          <p class="truncate text-xs text-muted-foreground">X posting</p>
        </div>
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
          {#if attention}
            <span
              class="inline-flex shrink-0 items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900 dark:bg-amber-950 dark:text-amber-200"
              data-testid="x-posting-attention">
              <WarningCircle size={14} weight="bold" />
              {attention}
            </span>
          {/if}
          <span
            class={`inline-flex min-w-0 items-center gap-1.5 ${granted.length === 0 ? 'italic text-muted-foreground/80' : 'text-muted-foreground'}`}
            data-testid="x-posting-summary">
            <UsersThree size={16} class="shrink-0" />
            <span class="break-words">{summary}</span>
          </span>
        </div>
      </div>
      <CaretDown size={18} class={`shrink-0 text-muted-foreground transition-transform ${open ? 'rotate-180' : ''}`} />
    </button>
  {/if}

  {#if open}
    <div id="x-posting-panel" class="space-y-4 border-t px-4 pb-5 pt-4 sm:px-6">
      <a href={x.page_url} class="inline-flex items-center gap-1.5 text-sm underline-offset-4 hover:underline">
        Connection, X app and the account-wide switch are on the X page <ArrowRight size={14} />
      </a>
      <div class="space-y-3 border-t pt-4">
        <h4 class="text-sm font-semibold">Resident access</h4>
        <p class="text-xs text-muted-foreground">
          A resident switched on here can publish under the account's X handle while posting is on.
        </p>
        {#if x.residents.length === 0}
          <p class="text-sm text-muted-foreground">There are no residents in this account yet.</p>
        {:else}
          <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {#each x.residents as resident (resident.id)}
              <div class="flex items-center justify-between gap-4 rounded-lg border bg-background px-3 py-2.5">
                <label class="block min-w-0 truncate text-sm font-medium" for={`x-posting-${resident.id}`}>
                  {resident.name}
                  {#if !resident.active}<span class="text-xs font-normal text-muted-foreground"> (retired)</span>{/if}
                </label>
                <Switch
                  id={`x-posting-${resident.id}`}
                  checked={resident.enabled}
                  disabled={!x.can_manage || updating[resident.id]}
                  onCheckedChange={(checked) => toggleResident(resident, checked)} />
              </div>
            {/each}
          </div>
          {#if !x.can_manage}
            <p class="text-xs text-muted-foreground">Account admins change who can post.</p>
          {/if}
        {/if}
      </div>
    </div>
  {/if}
</div>
