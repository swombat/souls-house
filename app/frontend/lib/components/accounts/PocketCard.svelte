<script>
  // A pocket device (YZWBVe): who owns it, which resident and conversation
  // it talks to, and its microphone and camera switches.
  import { Camera, DeviceMobile, Microphone } from 'phosphor-svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import DeviceControls from '$lib/components/accounts/DeviceControls.svelte';

  let { account, device, state, manages = false, busy = false, onsend, onremove } = $props();

  const statusLabel = { online: 'Online', paused: 'Paused', offline: 'Offline' };
  const captureLabel = { mic: 'Microphone', camera: 'Camera' };
  let pocket = $derived(device.pocket);
  let resident = $derived(device.residents[0]);

  // Turning a capture on is the owner's alone; turning it off is for whoever
  // manages the device. The server enforces both; this only mirrors it.
  const captureLocked = (capability) => (pocket[capability] ? !manages : !pocket.owned_by_you);
</script>

<article class="overflow-hidden rounded-2xl border bg-card shadow-sm" data-testid="pocket" data-status={state}>
  <div class="p-4 sm:px-5">
    <div class="flex items-start gap-3 sm:gap-4">
      <div
        class="relative flex size-12 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-slate-800 to-slate-950 text-white shadow-inner">
        <DeviceMobile size={24} />
        <span class="absolute -bottom-0.5 -right-0.5 flex size-3.5 items-center justify-center rounded-full bg-card">
          <span
            class={`size-2.5 rounded-full ${
              state === 'online' ? 'bg-emerald-500' : state === 'paused' ? 'bg-amber-500' : 'bg-zinc-400'
            }`}></span>
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
        <p class="mt-1 text-sm text-muted-foreground" data-testid="pocket-owner">Owner: {pocket.owner_name}</p>
        <p class="mt-1 text-sm" data-testid="pocket-talks-to">
          Talks to {resident?.name ?? 'no one'} in
          <a href="/accounts/{account.id}/chats/{pocket.chat_id}" class="font-medium underline underline-offset-4"
            >«{pocket.chat_title}»</a>
        </p>
      </div>
    </div>
  </div>

  <div class="space-y-4 border-t bg-muted/20 px-4 pb-5 pt-4 sm:px-5">
    {#if manages}
      <DeviceControls
        {device}
        {state}
        {busy}
        offline="The device isn't connected right now."
        online="Connected."
        {onsend}
        {onremove} />
    {/if}

    <section class="divide-y rounded-xl border bg-card">
      {#each pocket.capabilities as capability (capability)}
        <div class="px-4 py-3" data-testid="pocket-capture">
          <div class="flex items-center justify-between gap-4">
            <Label for="capture-{device.id}-{capability}" class="flex min-w-0 items-center gap-2.5 font-normal">
              {#if capability === 'mic'}
                <Microphone size={18} class="shrink-0 text-muted-foreground" />
              {:else}
                <Camera size={18} class="shrink-0 text-muted-foreground" />
              {/if}
              <span>{captureLabel[capability] ?? capability}</span>
            </Label>
            <Switch
              id="capture-{device.id}-{capability}"
              checked={!!pocket[capability]}
              disabled={busy || captureLocked(capability)}
              onCheckedChange={(value) => onsend({ control: 'capture', capability, value: String(value) })} />
          </div>
          {#if !pocket.owned_by_you && !pocket[capability]}
            <p class="mt-2 text-xs text-muted-foreground">Only {pocket.owner_name} can turn this on</p>
          {/if}
        </div>
      {/each}
    </section>
  </div>
</article>
