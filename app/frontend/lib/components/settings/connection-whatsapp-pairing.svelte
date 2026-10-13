<script>
  import { router } from '@inertiajs/svelte';
  import { untrack } from 'svelte';
  import QRCode from 'qrcode';
  import { Button } from '$lib/components/shadcn/button';
  import { formatCountdown, postLoginJson, secondsUntil } from '$lib/telegram-connection';
  import { newerQr, pairingPhase } from '$lib/whatsapp-pairing';

  // The QR code comes only from the owner's pairing endpoint, by fetch: it
  // never enters page props, browser history or the console.
  let { connection, account, pollInterval = 2500 } = $props();

  let loaded = $state(false);
  let notOwner = $state(false);
  let status = $state(untrack(() => connection.status));
  let qr = $state(null);
  let now = $state(Date.now());
  let qrImage = $state(null);
  let busy = $state(false);
  let notice = $state(null);

  const base = $derived(`/accounts/${account.id}/service_connections/${connection.id}`);
  const polling = $derived(connection.status === 'pairing');
  const secondsLeft = $derived(qr?.expires_at ? secondsUntil(qr.expires_at, now) : 0);
  const secondsSinceExpiry = $derived(
    qr?.expires_at ? Math.max(0, Math.floor((now - Date.parse(qr.expires_at)) / 1000)) : 0
  );
  const phase = $derived(pairingPhase({ status, qr, secondsLeft, secondsSinceExpiry }));
  const showQr = $derived(['scan', 'rotating', 'expired'].includes(phase));

  async function poll() {
    let response;
    try {
      response = await fetch(`${base}/pairing`, {
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { Accept: 'application/json' },
      });
    } catch {
      return true;
    }
    if (response.status === 404) {
      notOwner = true;
      loaded = true;
      return false;
    }
    if (!response.ok) return true;
    const json = await response.json();
    loaded = true;
    status = json.status;
    qr = newerQr(qr, json.qr, Date.now());
    if (json.status === 'pairing') return true;
    // Linked, logged out or failed: the card's header and the rest of the
    // page follow the connection's new status.
    router.reload();
    return false;
  }

  $effect(() => {
    if (!polling) {
      status = connection.status;
      loaded = true;
      return;
    }
    let stopped = false;
    let timer;
    const tick = async () => {
      const again = await poll();
      if (!stopped && again) timer = setTimeout(tick, pollInterval);
    };
    untrack(tick);
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  });

  $effect(() => {
    if (!qr?.expires_at) return;
    now = Date.now();
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  $effect(() => {
    const code = qr?.code;
    if (!code) {
      qrImage = null;
      return;
    }
    let current = true;
    QRCode.toDataURL(code, { margin: 1, width: 240, errorCorrectionLevel: 'M' })
      .then((url) => current && (qrImage = url))
      .catch(() => current && (qrImage = null));
    return () => (current = false);
  });

  async function restart() {
    busy = true;
    notice = null;
    const result = await postLoginJson(`${base}/pairing/restart`);
    busy = false;
    if (result.ok) {
      qr = null;
      status = result.body.status || 'pairing';
      router.reload();
    } else {
      notice = result.body.error || 'Something went wrong. Try again.';
    }
  }
</script>

<section class="space-y-4 rounded-lg border bg-muted/30 p-4" data-testid="whatsapp-pairing" aria-live="polite">
  {#if notOwner}
    <p class="text-sm text-muted-foreground">Waiting for the person who connected it to link it.</p>
  {:else if !loaded}
    <p class="text-sm text-muted-foreground">Checking the pairing.</p>
  {:else}
    {#if phase === 'logged_out'}
      <p class="text-sm">
        WhatsApp logged this linked device out. Pair again so residents can keep reading these chats.
      </p>
    {:else if phase === 'error'}
      <p class="text-sm text-destructive" role="alert">Pairing failed. Restart pairing to try again.</p>
    {:else if phase === 'connected'}
      <p class="text-sm text-emerald-700">Linked. Loading the connection.</p>
    {:else if showQr}
      <div class="flex flex-col gap-4 sm:flex-row sm:items-start">
        <div class="w-fit shrink-0 rounded-lg bg-white p-2">
          {#if qrImage}
            <img
              src={qrImage}
              alt="WhatsApp pairing QR code"
              width="200"
              height="200"
              data-issued-at={qr.issued_at}
              class={`size-[200px] ${phase === 'scan' ? '' : 'opacity-30'}`} />
          {:else}
            <div class="size-[200px]"></div>
          {/if}
        </div>
        <div class="min-w-0 space-y-2 text-sm">
          <p class="font-medium">Scan this code with WhatsApp on your phone.</p>
          <ol class="list-decimal space-y-1 pl-5 text-muted-foreground">
            <li>Open WhatsApp and go to Settings, then Linked devices.</li>
            <li>Tap Link a device.</li>
            <li>Point the camera at this code.</li>
          </ol>
          <p
            class={phase === 'expired' ? 'text-destructive' : 'text-muted-foreground'}
            data-testid="whatsapp-qr-countdown">
            {#if phase === 'scan'}
              This code expires in {formatCountdown(secondsLeft)}. A new one appears by itself.
            {:else if phase === 'rotating'}
              This code expired. Waiting for a new one.
            {:else}
              Pairing timed out: WhatsApp stopped sending codes. Restart pairing for a new one.
            {/if}
          </p>
        </div>
      </div>
    {:else if phase === 'waiting'}
      <p class="text-sm text-muted-foreground">Waiting for a pairing code from WhatsApp.</p>
    {/if}

    {#if notice}
      <p class="text-sm text-destructive" role="status">{notice}</p>
    {/if}

    {#if phase !== 'connected'}
      <div class="flex flex-wrap gap-2">
        <Button
          type="button"
          variant={phase === 'expired' || phase === 'logged_out' || phase === 'error' ? 'default' : 'outline'}
          size="sm"
          disabled={busy}
          onclick={restart}>
          {phase === 'logged_out' ? 'Pair again' : 'Restart pairing'}
        </Button>
      </div>
    {/if}
  {/if}
</section>
