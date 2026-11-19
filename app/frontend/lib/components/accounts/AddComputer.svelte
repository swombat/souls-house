<script>
  // "Add a computer": type the code the companion is showing, see what that
  // computer offers, choose residents and access, approve. The computer then
  // finishes pairing on its own. Owners and admins only (the server checks).
  import { router } from '@inertiajs/svelte';
  import { Plus, WarningCircle } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { csrfToken } from '$lib/chat-utils.js';
  import { ACCESS_RANK, ACCESS_LABEL } from '$lib/companion-volumes.js';

  let { account, warnings = {}, size = 'default', startOpen = false } = $props();

  let open = $state(startOpen);
  let code = $state('');
  let offer = $state(null);
  let error = $state(null);
  let busy = $state(false);
  let chosen = $state({});
  let accesses = $state({});
  // Each lookup gets a number; a reply that arrives after the code was
  // edited, the dialog closed or another lookup started is dropped, so what
  // is approved is always the offer on screen.
  let seq = 0;

  function reset() {
    seq += 1;
    busy = false;
    code = '';
    offer = null;
    error = null;
    chosen = {};
    accesses = {};
  }

  async function lookup(event) {
    event?.preventDefault();
    if (busy || !code.trim()) return;
    busy = true;
    error = null;
    const mine = ++seq;
    const submitted = code;
    try {
      const response = await fetch(`/accounts/${account.id}/computers/pairings/lookup`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken(), 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ code: submitted }),
      });
      const body = await response.json().catch(() => ({}));
      if (mine !== seq) return;
      if (!response.ok) {
        error = body.error ?? 'That code could not be checked. Try again.';
        return;
      }
      offer = { ...body, code: submitted };
      accesses = Object.fromEntries(body.volumes.map((v) => [v.volume, 'read']));
      chosen = body.residents.length === 1 ? { [body.residents[0].id]: true } : {};
    } catch {
      if (mine === seq) error = 'That code could not be checked. Try again.';
    } finally {
      if (mine === seq) busy = false;
    }
  }

  const choices = (volume) => ['off', 'read', 'write'].filter((a) => ACCESS_RANK[a] <= ACCESS_RANK[volume.access]);
  let residentIds = $derived(Object.keys(chosen).filter((id) => chosen[id]));
  let anyDisk = $derived(Object.values(accesses).some((a) => a !== 'off'));
  let anyWrite = $derived(Object.values(accesses).includes('write'));

  function approve() {
    if (busy || !residentIds.length || !anyDisk) return;
    busy = true;
    router.post(
      `/accounts/${account.id}/computers/pairings`,
      { code: offer.code, pairing_id: offer.id, resident_ids: residentIds, accesses },
      {
        preserveScroll: true,
        onFinish: () => {
          busy = false;
          open = false;
          reset();
        },
      }
    );
  }
</script>

<Button {size} onclick={() => (open = true)} data-testid="add-computer">
  <Plus size={16} /> Add a computer
</Button>

<Dialog.Root
  bind:open
  onOpenChange={(value) => {
    if (!value) reset();
  }}>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title>{offer ? `Add ${offer.name}` : 'Add a computer'}</Dialog.Title>
      <Dialog.Description>
        {#if offer}
          It will be added to <strong>{offer.account_name}</strong>. Choose who may use it and what they may reach. They
          can never reach more than the computer offers.
        {:else}
          On the computer, open the souls.house menu, choose “Pair this Mac…”, and type the code it shows.
        {/if}
      </Dialog.Description>
    </Dialog.Header>

    {#if !offer}
      <form onsubmit={lookup} class="space-y-3">
        <Label for="pairing-code">Code</Label>
        <Input
          id="pairing-code"
          bind:value={code}
          disabled={busy}
          placeholder="ABCD-EFGH"
          autocomplete="off"
          autocapitalize="characters"
          spellcheck="false"
          class="font-mono text-lg tracking-widest uppercase"
          data-testid="pairing-code" />
        {#if error}
          <p class="text-sm text-destructive" data-testid="pairing-error">{error}</p>
        {/if}
        <Dialog.Footer>
          <Button type="submit" disabled={busy || !code.trim()}>Continue</Button>
        </Dialog.Footer>
      </form>
    {:else}
      <div class="space-y-5">
        <div>
          <p class="mb-2 text-sm font-medium">Residents</p>
          {#each offer.residents as resident (resident.id)}
            <label class="flex items-center gap-2 py-1 text-sm">
              <input type="checkbox" bind:checked={chosen[resident.id]} data-testid="pairing-resident" />
              {resident.name}
            </label>
          {/each}
        </div>
        <div>
          <p class="mb-2 text-sm font-medium">Disks</p>
          {#each offer.volumes as volume (volume.volume)}
            <div class="flex items-center justify-between gap-3 py-1 text-sm">
              <span>{volume.label}</span>
              <select
                bind:value={accesses[volume.volume]}
                class="rounded-md border bg-background px-2 py-1"
                data-testid="pairing-access">
                {#each choices(volume) as choice}
                  <option value={choice}>{ACCESS_LABEL[choice]}</option>
                {/each}
              </select>
            </div>
          {/each}
        </div>
        {#if anyWrite && warnings.write}
          <p class="flex gap-2 rounded-lg bg-muted p-3 text-xs text-muted-foreground">
            <WarningCircle size={16} class="shrink-0" />
            {warnings.write}
          </p>
        {/if}
        <Dialog.Footer>
          <Button variant="outline" onclick={reset} disabled={busy}>Back</Button>
          <Button onclick={approve} disabled={busy || !residentIds.length || !anyDisk} data-testid="pairing-approve">
            Add {offer.name}
          </Button>
        </Dialog.Footer>
      </div>
    {/if}
  </Dialog.Content>
</Dialog.Root>
