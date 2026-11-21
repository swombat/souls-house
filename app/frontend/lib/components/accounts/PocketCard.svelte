<script>
  // A pocket device (YZWBVe): who owns it, which resident and conversation
  // it talks to, and its microphone and camera switches.
  import { Camera, DeviceMobile, LockSimple, Microphone } from 'phosphor-svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import DeviceControls from '$lib/components/accounts/DeviceControls.svelte';

  let { account, device, state: deviceState, manages = false, busy = false, onsend, onremove } = $props();

  const statusLabel = { online: 'Online', paused: 'Paused', offline: 'Offline' };
  const captureLabel = { mic: 'Microphone', camera: 'Camera' };
  let pocket = $derived(device.pocket);
  let resident = $derived(device.residents[0]);

  // Turning a capture on is the owner's alone; turning it off is for whoever
  // manages the device. The server enforces both; this only mirrors it.
  const captureLocked = (capability) => (pocket[capability] ? !manages : !pocket.owned_by_you);

  // The owner points the stone at another conversation, or a new one
  // (eKmnrJ). Only the owner sees this; the server checks it again.
  let choice = $state('');
  let newTitle = $state('');
  let newPrivate = $state(true);
  function changeConversation() {
    if (choice === 'new') {
      onsend({ control: 'conversation', new_conversation: 'true', title: newTitle, private: String(newPrivate) });
    } else if (choice) {
      onsend({ control: 'conversation', chat_id: choice });
    }
  }
</script>

<article class="overflow-hidden rounded-2xl border bg-card shadow-sm" data-testid="pocket" data-status={deviceState}>
  <div class="p-4 sm:px-5">
    <div class="flex items-start gap-3 sm:gap-4">
      <div
        class="relative flex size-12 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-slate-800 to-slate-950 text-white shadow-inner">
        <DeviceMobile size={24} />
        <span class="absolute -bottom-0.5 -right-0.5 flex size-3.5 items-center justify-center rounded-full bg-card">
          <span
            class={`size-2.5 rounded-full ${
              deviceState === 'online' ? 'bg-emerald-500' : deviceState === 'paused' ? 'bg-amber-500' : 'bg-zinc-400'
            }`}></span>
        </span>
      </div>
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <h3 class="truncate font-semibold leading-snug">{device.name}</h3>
          <span
            data-testid="computer-status"
            class={`rounded-full px-2 py-0.5 text-xs font-medium ${
              deviceState === 'online'
                ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-200'
                : deviceState === 'paused'
                  ? 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
                  : 'bg-muted text-muted-foreground'
            }`}>
            {statusLabel[deviceState]}
          </span>
        </div>
        <p class="mt-1 text-sm text-muted-foreground" data-testid="pocket-owner">Owner: {pocket.owner_name}</p>
        <p class="mt-1 text-sm" data-testid="pocket-talks-to">
          Talks to {resident?.name ?? 'no one'} in
          {#if pocket.chat_id}
            <a href="/accounts/{account.id}/chats/{pocket.chat_id}" class="font-medium underline underline-offset-4"
              >«{pocket.chat_title}»</a>
          {:else}
            <span class="font-medium">{pocket.chat_title}</span>
          {/if}
          {#if pocket.chat_private}
            <LockSimple size={12} class="inline text-muted-foreground" aria-label="Private" />
          {/if}
        </p>
      </div>
    </div>
  </div>

  <div class="space-y-4 border-t bg-muted/20 px-4 pb-5 pt-4 sm:px-5">
    {#if manages}
      <DeviceControls
        {device}
        state={deviceState}
        {busy}
        offline="The device isn't connected right now."
        online="Connected."
        {onsend}
        {onremove} />
    {/if}

    {#if pocket.owned_by_you}
      <section class="space-y-2 rounded-xl border bg-card px-4 py-3" data-testid="pocket-conversation">
        <Label for="pocket-chat-{device.id}">Conversation</Label>
        <select
          id="pocket-chat-{device.id}"
          class="w-full rounded-md border bg-background px-2 py-1.5 text-sm"
          bind:value={choice}
          disabled={busy}>
          <option value="">Keep the current one</option>
          {#each pocket.conversation_choices ?? [] as option (option.id)}
            {#if option.id !== pocket.chat_id}
              <option value={option.id}>{option.title}{option.private ? ' (private)' : ''}</option>
            {/if}
          {/each}
          <option value="new">A new conversation…</option>
        </select>
        {#if choice === 'new'}
          <input
            class="w-full rounded-md border bg-background px-2 py-1.5 text-sm"
            placeholder="Name (optional)"
            maxlength="200"
            bind:value={newTitle} />
          <label class="flex items-start gap-2 text-sm">
            <input type="checkbox" class="mt-0.5" bind:checked={newPrivate} />
            <span
              >Private: only you and {resident?.name ?? 'its resident'} can see it, account admins included. It isn't private
              from the house's operators.</span>
          </label>
        {/if}
        <button
          type="button"
          class="rounded-md border px-3 py-1.5 text-sm font-medium disabled:opacity-50"
          disabled={busy || !choice}
          onclick={changeConversation}>Move the stone here</button>
        <p class="text-xs text-muted-foreground">
          Only the conversation changes. Its history stays where it is, and a reply still on its way lands in the old
          one.
        </p>
      </section>
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
