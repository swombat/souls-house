<script>
  import { router } from '@inertiajs/svelte';
  import {
    AppleLogo,
    CaretDown,
    Desktop,
    FolderSimple,
    LinuxLogo,
    Pause,
    Play,
    Terminal,
    Trash,
    UsersThree,
    WarningCircle,
  } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Switch } from '$lib/components/shadcn/switch';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import CompanionDownload from '$lib/components/companion/CompanionDownload.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ResidentFolders from '$lib/components/accounts/ResidentFolders.svelte';
  import { diskName } from '$lib/companion-volumes.js';
  import { createDynamicSync } from '$lib/use-sync';

  let { account, devices = [], can_manage = false, warnings = {} } = $props();

  // A computer that connects, drops or changes tells this page to reload its
  // devices. Without it, a change's brief reconnect gap stayed "Offline".
  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({ [`ComputerStatus:${account.id}`]: ['devices'] });
  });

  // Each computer is a summary card; its settings open underneath, like
  // Integrations. A single computer starts open, a fleet starts closed.
  let openCards = $state({});
  const isOpen = (device) => openCards[device.id] ?? devices.length === 1;
  const toggle = (device) => (openCards[device.id] = !isOpen(device));

  // A change waiting for the owner's confirmation: turning a power on, or
  // removing a computer. Turning a power off needs no confirmation.
  let pending = $state(null);
  let busy = $state(false);
  // Bumped whenever a change finishes or is cancelled, so every folder
  // choice is redrawn from what the server has, not left at what was picked.
  let redraw = $state(0);
  function cancel() {
    if (busy) return;
    pending = null;
    redraw += 1;
  }

  const path = (device) => `/accounts/${account.id}/computers/${device.id}`;

  function send(device, data) {
    if (busy) return;
    busy = true;
    router.patch(path(device), data, {
      preserveScroll: true,
      onFinish: () => {
        busy = false;
        pending = null;
        redraw += 1;
      },
    });
  }

  function authority(device, resident, kind, value) {
    // Only the switch that was touched is sent. The other permission is
    // left as the server has it, which may differ from what this page shows.
    const next = { control: 'authority', resident_id: resident.id, permission: kind, value };
    if (value) {
      pending = { device, data: next, title: confirmTitle(kind, resident, device), body: warnings[kind] };
    } else {
      send(device, next);
    }
  }

  function confirmTitle(kind, resident, device) {
    return kind === 'execute'
      ? `Let ${resident.name} run commands on ${device.name}?`
      : `Let ${resident.name} use apps on ${device.name}?`;
  }

  function remove(device) {
    pending = {
      device,
      data: { control: 'revoke' },
      title: `Remove ${device.name}?`,
      body: 'It stops at once and cannot connect again. To use it later, enrol it again.',
      destructive: true,
    };
  }

  const status = (device) => (device.paused ? 'paused' : device.connected ? 'online' : 'offline');
  const statusLabel = { online: 'Online', paused: 'Paused', offline: 'Offline' };

  function platform(device) {
    const kinds = device.residents.flatMap((r) => r.volumes.map((v) => String(v.volume).split(':')[0]));
    if (kinds.includes('darwin-volume')) return 'mac';
    if (kinds.includes('linux-volume')) return 'linux';
    return null;
  }

  function timeAgo(iso) {
    if (!iso) return null;
    const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (seconds < 60) return 'just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} min ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours} h ago`;
    const days = Math.floor(hours / 24);
    return days === 1 ? 'yesterday' : `${days} days ago`;
  }
  const enrolled = (iso) =>
    iso ? new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : null;

  const weekJobs = (device) => (device.activity?.days ?? []).reduce((sum, day) => sum + day.jobs, 0);
  const peak = (device) => Math.max(1, ...(device.activity?.days ?? []).map((day) => day.jobs));
  const weekday = (date) => new Date(`${date}T12:00:00Z`).toLocaleDateString(undefined, { weekday: 'narrow' });

  function access(resident) {
    const powers = [
      resident.execute && 'commands',
      resident.desktop && 'apps',
      resident.volumes.length && 'folders',
    ].filter(Boolean);
    return powers.length ? powers.join(' + ') : 'nothing allowed yet';
  }

  let online = $derived(devices.filter((d) => status(d) === 'online').length);
  let jobsThisWeek = $derived(devices.reduce((sum, d) => sum + weekJobs(d), 0));

  function folder(device, resident, row, access) {
    if (access === row.current) return;
    // Only the folder that was touched is sent; every other folder and both
    // switches stay as the server has them.
    const data = { control: 'volume', resident_id: resident.id, volume: row.volume, access };
    if (access === 'write') {
      pending = {
        device,
        data,
        title: `Let ${resident.name} write to ${diskName(row.volume)} on ${device.name}?`,
        body: warnings.write,
      };
    } else {
      send(device, data);
    }
  }
</script>

<svelte:head>
  <title>Computers · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="computers"
  title="Computers"
  description="Computers enrolled with the companion app, which residents each one serves, and what they may do there.">
  {#if devices.length > 0}
    <div class="mb-4 flex flex-wrap items-center gap-3 text-sm" data-testid="companion-header">
      <CompanionDownload size="sm" early={false} />
      <a href="/companion" class="underline underline-offset-4">About the companion app</a>
    </div>
  {/if}
  <FlashMessages />

  {#if devices.length === 0}
    <div class="rounded-2xl border border-dashed bg-muted/30 p-10 text-center">
      <div class="mx-auto flex size-12 items-center justify-center rounded-xl bg-muted">
        <Desktop size={26} />
      </div>
      <p class="mt-3 font-medium">No computers yet</p>
      <p class="mx-auto mt-1 max-w-md text-sm text-muted-foreground">
        The companion app lets residents work on your own computer, in the folders you grant and with the apps you
        allow.
      </p>
      <div class="mt-5 flex justify-center"><CompanionDownload size="default" /></div>
      <ol
        class="mx-auto mt-6 max-w-md list-decimal space-y-2 pl-5 text-left text-sm text-muted-foreground"
        data-testid="companion-enrol-steps">
        <li>Install the companion on the computer, as yourself.</li>
        <li>Set the computer's own ceiling: the folders the companion's file tools may ever reach there.</li>
        <li>
          An owner or admin makes a one-use grant naming the residents and what each may do. This is done through the
          house's API with your own key for now; a resident can walk you through it, but the grant comes from you.
        </li>
        <li>Run the one enrol command on the computer. The computer then appears here.</li>
      </ol>
      <a href="/companion" class="mt-5 inline-block text-sm font-medium underline underline-offset-4">
        About the companion app
      </a>
    </div>
  {:else}
    <div class="mb-5 grid grid-cols-3 overflow-hidden rounded-2xl border bg-card" data-testid="fleet-summary">
      <div class="p-4">
        <p class="text-2xl font-semibold tabular-nums">{devices.length}</p>
        <p class="text-xs text-muted-foreground">{devices.length === 1 ? 'computer' : 'computers'}</p>
      </div>
      <div class="border-l p-4">
        <p class="flex items-center gap-2 text-2xl font-semibold tabular-nums">
          {online}
          {#if online > 0}<span class="size-2 rounded-full bg-emerald-500"></span>{/if}
        </p>
        <p class="text-xs text-muted-foreground">online now</p>
      </div>
      <div class="border-l p-4">
        <p class="text-2xl font-semibold tabular-nums">{jobsThisWeek}</p>
        <p class="text-xs text-muted-foreground">jobs this week</p>
      </div>
    </div>
  {/if}

  {#if devices.length > 0 && !can_manage}
    <p class="mb-4 text-sm text-muted-foreground">Only an owner or admin of this account can change these.</p>
  {/if}

  <div class="space-y-3">
    {#each devices as device (device.id)}
      {@const state = status(device)}
      {@const open = isOpen(device)}
      {@const os = platform(device)}
      {@const lastJob = timeAgo(device.activity?.last_job_at)}
      <article class="overflow-hidden rounded-2xl border bg-card shadow-sm" data-testid="computer" data-status={state}>
        <div class="relative p-4 sm:px-5">
          <button
            type="button"
            class="absolute inset-0 rounded-2xl transition hover:bg-muted/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
            aria-expanded={open}
            aria-controls="computer-panel-{device.id}"
            aria-label="{open ? 'Hide' : 'Show'} settings for {device.name}"
            onclick={() => toggle(device)}></button>

          <div class="pointer-events-none relative flex items-start gap-3 sm:gap-4">
            <div
              class="relative flex size-12 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-slate-800 to-slate-950 text-white shadow-inner">
              {#if os === 'mac'}
                <AppleLogo size={24} weight="fill" />
              {:else if os === 'linux'}
                <LinuxLogo size={24} weight="fill" />
              {:else}
                <Desktop size={24} />
              {/if}
              <span
                class="absolute -bottom-0.5 -right-0.5 flex size-3.5 items-center justify-center rounded-full bg-card">
                <span
                  class={`size-2.5 rounded-full ${
                    state === 'online' ? 'bg-emerald-500' : state === 'paused' ? 'bg-amber-500' : 'bg-zinc-400'
                  }`}>
                  {#if state === 'online'}
                    <span class="block size-2.5 animate-ping rounded-full bg-emerald-500 opacity-60"></span>
                  {/if}
                </span>
              </span>
            </div>

            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <h3 class="truncate font-semibold leading-snug">{device.name}</h3>
                <span
                  data-testid="computer-status"
                  class={`rounded-full px-2 py-0.5 text-xs font-medium ${
                    state === 'online'
                      ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-200'
                      : state === 'paused'
                        ? 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
                        : 'bg-muted text-muted-foreground'
                  }`}>
                  {statusLabel[state]}
                </span>
              </div>
              <ul class="mt-2 flex flex-wrap gap-1.5" data-testid="computer-access-summary" aria-label="Who it serves">
                {#each device.residents as resident (resident.id)}
                  <li
                    class="inline-flex items-center gap-1.5 rounded-full border bg-background py-0.5 pl-0.5 pr-2 text-xs"
                    title="{resident.name}: {access(resident)}">
                    <span
                      class="flex size-5 items-center justify-center rounded-full bg-primary/10 text-[10px] font-semibold text-primary">
                      {resident.name.slice(0, 1)}
                    </span>
                    <span class="font-medium">{resident.name}</span>
                    {#if resident.execute}<Terminal
                        size={12}
                        class="text-muted-foreground"
                        aria-label="runs commands" />{/if}
                    {#if resident.desktop}<Desktop
                        size={12}
                        class="text-muted-foreground"
                        aria-label="uses apps" />{/if}
                    {#if resident.volumes.length}<FolderSimple
                        size={12}
                        class="text-muted-foreground"
                        aria-label="folders" />{/if}
                  </li>
                {:else}
                  <li class="text-xs italic text-muted-foreground">Serves no one</li>
                {/each}
              </ul>
            </div>

            <CaretDown
              size={18}
              class={`mt-1 shrink-0 text-muted-foreground transition-transform ${open ? 'rotate-180' : ''}`} />
          </div>

          <div
            class="pointer-events-none relative mt-4 grid grid-cols-[1fr_auto_auto] items-end gap-4 rounded-xl bg-muted/50 px-3 py-2.5 sm:gap-6">
            <div class="flex h-10 w-full max-w-[14rem] items-end gap-1" aria-hidden="true">
              {#each device.activity?.days ?? [] as day (day.date)}
                <div class="flex min-w-0 flex-1 flex-col items-center gap-1">
                  <div
                    class={`w-full max-w-4 rounded-sm ${day.jobs ? (state === 'online' ? 'bg-emerald-500/80' : 'bg-foreground/40') : 'bg-foreground/10'}`}
                    style="height: {Math.max(3, Math.round((day.jobs / peak(device)) * 26))}px">
                  </div>
                  <span class="text-[9px] leading-none text-muted-foreground">{weekday(day.date)}</span>
                </div>
              {/each}
            </div>
            <div class="text-right">
              <p class="text-lg font-semibold leading-tight tabular-nums" data-testid="computer-week-jobs">
                {weekJobs(device)}
                <span class="text-xs font-normal text-muted-foreground">{weekJobs(device) === 1 ? 'job' : 'jobs'}</span>
              </p>
              <p class="text-[11px] text-muted-foreground">
                {#if device.activity?.failed}
                  <span class="text-amber-700 dark:text-amber-300">{device.activity.failed} failed</span>
                {:else}
                  this week
                {/if}
              </p>
            </div>
            <div class="text-right">
              <p class="text-sm font-medium leading-tight">{lastJob ?? 'none yet'}</p>
              <p class="text-[11px] text-muted-foreground">last job</p>
            </div>
          </div>
        </div>

        {#if open}
          <div id="computer-panel-{device.id}" class="space-y-4 border-t bg-muted/20 px-4 pb-5 pt-4 sm:px-5">
            {#if can_manage}
              <div class="flex flex-wrap items-center justify-between gap-2">
                <p class="text-sm text-muted-foreground">
                  {#if state === 'paused'}
                    Nothing runs here until you resume it.
                  {:else if state === 'offline'}
                    The companion app isn't connected right now.
                  {:else}
                    Connected and taking jobs.
                  {/if}
                  {#if device.enrolled_at}
                    <span class="block text-xs">Enrolled {enrolled(device.enrolled_at)}</span>
                  {/if}
                </p>
                <div class="flex gap-2">
                  {#if device.paused}
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={busy}
                      onclick={() => send(device, { control: 'resume' })}>
                      <Play class="mr-1" size={16} /> Resume
                    </Button>
                  {:else}
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={busy}
                      onclick={() => send(device, { control: 'pause' })}>
                      <Pause class="mr-1" size={16} /> Pause
                    </Button>
                  {/if}
                  <Button
                    variant="ghost"
                    size="sm"
                    class="text-destructive hover:text-destructive"
                    disabled={busy}
                    onclick={() => remove(device)}
                    aria-label="Remove {device.name}">
                    <Trash size={16} />
                  </Button>
                </div>
              </div>
            {/if}

            {#each device.residents as resident (resident.id)}
              <section class="rounded-xl border bg-card" data-testid="computer-resident">
                <div class="flex items-center gap-3 border-b px-4 py-3">
                  <span
                    class="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/10 text-sm font-semibold text-primary">
                    {resident.name.slice(0, 1)}
                  </span>
                  <p class="min-w-0 flex-1 truncate font-medium">{resident.name}</p>
                </div>
                <div class="divide-y">
                  <div class="flex items-center justify-between gap-4 px-4 py-3">
                    <Label
                      for="execute-{device.id}-{resident.id}"
                      class="flex min-w-0 items-center gap-2.5 font-normal">
                      <Terminal size={18} class="shrink-0 text-muted-foreground" />
                      <span>Run commands</span>
                    </Label>
                    <Switch
                      id="execute-{device.id}-{resident.id}"
                      checked={resident.execute}
                      disabled={!can_manage || busy}
                      onCheckedChange={(value) => authority(device, resident, 'execute', value)} />
                  </div>
                  <div class="px-4 py-3">
                    <div class="flex items-center justify-between gap-4">
                      <Label
                        for="desktop-{device.id}-{resident.id}"
                        class="flex min-w-0 items-center gap-2.5 font-normal">
                        <Desktop size={18} class="shrink-0 text-muted-foreground" />
                        <span>Use apps (desktop)</span>
                      </Label>
                      <Switch
                        id="desktop-{device.id}-{resident.id}"
                        checked={resident.desktop}
                        disabled={!can_manage || busy}
                        onCheckedChange={(value) => authority(device, resident, 'desktop', value)} />
                    </div>
                    {#if resident.desktop}
                      <p class="mt-2 flex gap-1.5 text-xs text-muted-foreground">
                        <WarningCircle size={14} class="mt-px shrink-0" />
                        Also needs the switch in the menu bar on that computer, and only reaches the apps listed there.
                      </p>
                    {/if}
                  </div>
                  <div class="px-4 py-3">
                    <p class="flex items-center gap-2.5 text-sm">
                      <FolderSimple size={18} class="shrink-0 text-muted-foreground" />
                      Folders
                    </p>
                    <ResidentFolders
                      {device}
                      {resident}
                      {can_manage}
                      {busy}
                      {redraw}
                      onchoose={(row, access) => folder(device, resident, row, access)} />
                  </div>
                </div>
              </section>
            {/each}
          </div>
        {/if}
      </article>
    {/each}
  </div>
</AccountSettingsLayout>

<Dialog.Root open={pending !== null} onOpenChange={(open) => !open && cancel()}>
  <Dialog.Content>
    <Dialog.Header>
      <Dialog.Title>{pending?.title}</Dialog.Title>
      <Dialog.Description>{pending?.body}</Dialog.Description>
    </Dialog.Header>
    <div class="flex justify-end gap-2">
      <Button variant="outline" disabled={busy} onclick={cancel}>Cancel</Button>
      <Button
        variant={pending?.destructive ? 'destructive' : 'default'}
        disabled={busy}
        onclick={() => send(pending.device, pending.data)}>
        {pending?.destructive ? 'Remove' : 'Allow'}
      </Button>
    </div>
  </Dialog.Content>
</Dialog.Root>
