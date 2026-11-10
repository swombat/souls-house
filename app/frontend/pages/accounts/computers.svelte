<script>
  import { router } from '@inertiajs/svelte';
  import { Desktop, Pause, Play, Trash, FolderSimple } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Switch } from '$lib/components/shadcn/switch';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Card from '$lib/components/shadcn/card';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  let { account, devices = [], can_manage = false, warnings = {} } = $props();

  // A change waiting for the owner's confirmation: turning a power on, or
  // removing a computer. Turning a power off needs no confirmation.
  let pending = $state(null);
  let busy = $state(false);
  function cancel() {
    if (busy) return;
    pending = null;
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
</script>

<svelte:head>
  <title>Computers · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="computers"
  title="Computers"
  description="Computers enrolled with the companion app, which residents each one serves, and what they may do there.">
  <FlashMessages />

  {#if !can_manage}
    <p class="mb-4 text-sm text-muted-foreground">Only an owner or admin of this account can change these.</p>
  {/if}

  {#if devices.length === 0}
    <Card.Root>
      <Card.Content class="py-8 text-center text-muted-foreground">
        No computers are enrolled yet. A resident can help you set one up.
      </Card.Content>
    </Card.Root>
  {/if}

  <div class="space-y-6">
    {#each devices as device (device.id)}
      <Card.Root data-testid="computer">
        <Card.Header class="flex flex-row items-start justify-between gap-4 space-y-0">
          <div class="min-w-0">
            <Card.Title class="flex items-center gap-2">
              <Desktop size={20} />
              <span class="truncate">{device.name}</span>
            </Card.Title>
            <div class="mt-2 flex flex-wrap gap-2">
              {#if device.paused}
                <Badge variant="secondary">Paused</Badge>
              {:else if device.connected}
                <Badge>Connected</Badge>
              {:else}
                <Badge variant="outline">Not connected</Badge>
              {/if}
            </div>
          </div>
          {#if can_manage}
            <div class="flex shrink-0 gap-2">
              {#if device.paused}
                <Button variant="outline" size="sm" disabled={busy} onclick={() => send(device, { control: 'resume' })}>
                  <Play class="mr-1" size={16} /> Resume
                </Button>
              {:else}
                <Button variant="outline" size="sm" disabled={busy} onclick={() => send(device, { control: 'pause' })}>
                  <Pause class="mr-1" size={16} /> Pause
                </Button>
              {/if}
              <Button
                variant="ghost"
                size="sm"
                disabled={busy}
                onclick={() => remove(device)}
                aria-label="Remove {device.name}">
                <Trash size={16} />
              </Button>
            </div>
          {/if}
        </Card.Header>
        <Card.Content class="space-y-4">
          {#each device.residents as resident (resident.id)}
            <div class="rounded-md border border-border p-4" data-testid="computer-resident">
              <p class="font-medium">{resident.name}</p>
              <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:gap-8">
                <div class="flex items-center gap-3">
                  <Switch
                    id="execute-{device.id}-{resident.id}"
                    checked={resident.execute}
                    disabled={!can_manage || busy}
                    onCheckedChange={(value) => authority(device, resident, 'execute', value)} />
                  <Label for="execute-{device.id}-{resident.id}" class="font-normal">Run commands</Label>
                </div>
                <div class="flex items-center gap-3">
                  <Switch
                    id="desktop-{device.id}-{resident.id}"
                    checked={resident.desktop}
                    disabled={!can_manage || busy}
                    onCheckedChange={(value) => authority(device, resident, 'desktop', value)} />
                  <Label for="desktop-{device.id}-{resident.id}" class="font-normal">Use apps (desktop)</Label>
                </div>
              </div>
              {#if resident.desktop}
                <p class="mt-2 text-xs text-muted-foreground">
                  Desktop still needs the switch in the menu bar on that computer, and only reaches the apps listed
                  there.
                </p>
              {/if}
              <div class="mt-3">
                <p class="text-xs font-medium text-muted-foreground">Folders</p>
                {#if resident.volumes.length === 0}
                  <p class="text-sm text-muted-foreground">None</p>
                {:else}
                  <ul class="mt-1 space-y-1">
                    {#each resident.volumes as volume (volume.volume)}
                      <li class="flex items-center gap-2 text-sm">
                        <FolderSimple size={14} />
                        <span class="truncate">{volume.volume}</span>
                        <Badge variant="outline">{volume.access === 'write' ? 'Read and write' : 'Read only'}</Badge>
                      </li>
                    {/each}
                  </ul>
                {/if}
                <p class="mt-1 text-xs text-muted-foreground">Changing folders needs a new enrollment for now.</p>
              </div>
            </div>
          {/each}
        </Card.Content>
      </Card.Root>
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
