<script>
  import { router } from '@inertiajs/svelte';
  import { untrack } from 'svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { postLoginJson, secondsUntil } from '$lib/telegram-connection';
  import {
    PHONE_FIRST_QUERY,
    defaultPairingMethod,
    newerQr,
    pairingPhase,
    phonePairingPhase,
    phonePairingUnderway,
  } from '$lib/whatsapp-pairing';
  import WhatsappQr from './connection-whatsapp-qr.svelte';
  import WhatsappPhone from './connection-whatsapp-phone.svelte';

  // The owner pairs WhatsApp by QR or by phone number ("Link with phone
  // number instead"). Both codes come only from the owner's pairing
  // endpoint, by fetch: never page props, browser history or the console.
  // phoneFirst: lead with the phone number. Left unset, a phone-sized or
  // touch screen decides (it cannot scan a QR on its own screen).
  let { connection, account, pollInterval = 2500, phoneFirst = undefined } = $props();

  let loaded = $state(false);
  let notOwner = $state(false);
  let status = $state(untrack(() => connection.status));
  let qr = $state(null);
  let phone = $state({});
  let phoneCode = $state(null);
  let attempt = $state(null);
  let now = $state(Date.now());
  let busy = $state(false);
  let notice = $state(null);
  let chosen = $state(null);
  let touchScreen = $state(false);

  const base = $derived(`/accounts/${account.id}/service_connections/${connection.id}`);
  const polling = $derived(connection.status === 'pairing');
  const secondsLeft = $derived(qr?.expires_at ? secondsUntil(qr.expires_at, now) : 0);
  const secondsSinceExpiry = $derived(
    qr?.expires_at ? Math.max(0, Math.floor((now - Date.parse(qr.expires_at)) / 1000)) : 0
  );
  const phase = $derived(pairingPhase({ status, qr, secondsLeft, secondsSinceExpiry }));
  const phoneSecondsLeft = $derived(phoneCode?.expires_at ? secondsUntil(phoneCode.expires_at, now) : 0);
  const phonePhase = $derived(phonePairingPhase({ status, phone, phoneCode, secondsLeft: phoneSecondsLeft }));
  const method = $derived(
    chosen ?? (phonePairingUnderway(phone, phoneCode) ? 'phone' : defaultPairingMethod(phoneFirst ?? touchScreen))
  );
  const pairing = $derived(['waiting', 'scan', 'rotating', 'expired'].includes(phase));
  const timedOut = $derived(method === 'phone' ? phonePhase === 'expired' : phase === 'expired');

  $effect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const query = window.matchMedia(PHONE_FIRST_QUERY);
    if (!query) return;
    touchScreen = query.matches;
    const change = (event) => (touchScreen = event.matches);
    query.addEventListener?.('change', change);
    return () => query.removeEventListener?.('change', change);
  });

  // Responses can arrive out of order: a poll sent before the owner
  // restarted, or sent a number, may answer after the change's own response
  // and must not undo it (bring back the old attempt, an old code, the old
  // step). `changes` counts the owner's changes; a poll is taken only if no
  // change began after it was sent, and a change's response only if no later
  // change began. `run` names the polling run, so nothing that answers after
  // polling has stopped is taken. Neither is reactive state. And attempts
  // only go up: a response for a lower attempt than the one shown is never
  // taken.
  let changes = 0;
  let run = 0;

  function take(json, since = changes) {
    if (since !== changes) return false;
    if (json.attempt != null && attempt != null && json.attempt < attempt) return false;
    status = json.status;
    qr = newerQr(qr, json.qr, Date.now());
    phone = json.phone ?? {};
    phoneCode = json.phone_code ?? null;
    attempt = json.attempt ?? attempt;
    return true;
  }

  // Called as a change starts; its result takes the change's response.
  function beginChange() {
    const mine = ++changes;
    return (json) => take(json, mine);
  }

  async function poll(token = run) {
    const since = changes;
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
    if (token !== run) return false;
    if (response.status === 404) {
      notOwner = true;
      loaded = true;
      return false;
    }
    if (!response.ok) return true;
    const json = await response.json();
    if (token !== run) return false;
    loaded = true;
    // Older than a change since: drop it and poll again.
    if (!take(json, since)) return true;
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
    const token = ++run;
    let timer;
    const tick = async () => {
      const again = await poll(token);
      if (token === run && again) timer = setTimeout(tick, pollInterval);
    };
    untrack(tick);
    return () => {
      run += 1;
      clearTimeout(timer);
    };
  });

  $effect(() => {
    if (!qr?.expires_at && !phoneCode?.expires_at) return;
    now = Date.now();
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  async function restart() {
    busy = true;
    notice = null;
    const commit = beginChange();
    const result = await postLoginJson(`${base}/pairing/restart`);
    busy = false;
    if (result.ok) {
      qr = null;
      commit({ phone: {}, phone_code: null, ...result.body, status: result.body.status || 'pairing' });
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
    {:else if pairing && method === 'phone'}
      <WhatsappPhone
        {base}
        {attempt}
        phase={phonePhase}
        {phoneCode}
        failure={phone.error}
        secondsLeft={phoneSecondsLeft}
        bind:busy
        begin={beginChange}
        onstale={poll}
        onnotice={(text) => (notice = text)} />
    {:else if pairing}
      <WhatsappQr {qr} {phase} {secondsLeft} />
    {/if}

    {#if notice}
      <p class="text-sm text-destructive" role="status">{notice}</p>
    {/if}

    {#if phase !== 'connected'}
      <div class="flex flex-wrap gap-2">
        <Button
          type="button"
          variant={timedOut || phase === 'logged_out' || phase === 'error' ? 'default' : 'outline'}
          size="sm"
          disabled={busy}
          onclick={restart}>
          {phase === 'logged_out' ? 'Pair again' : 'Restart pairing'}
        </Button>
        {#if pairing}
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={busy}
            onclick={() => {
              notice = null;
              chosen = method === 'phone' ? 'qr' : 'phone';
            }}>
            {method === 'phone' ? 'Scan a QR code instead' : 'Use a phone number instead'}
          </Button>
        {/if}
      </div>
    {/if}
  {/if}
</section>
