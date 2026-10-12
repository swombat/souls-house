<script>
  import { router } from '@inertiajs/svelte';
  import { untrack } from 'svelte';
  import QRCode from 'qrcode';
  import { Button } from '$lib/components/shadcn/button';
  import {
    formatCountdown,
    loginErrorMessage,
    passwordOutcomeMessage,
    postLoginJson,
    secondsUntil,
  } from '$lib/telegram-connection';

  let { connection, account, pollInterval = 2500 } = $props();

  let pairing = $state(null);
  let notOwner = $state(false);
  let now = $state(Date.now());
  let qrImage = $state(null);
  let busy = $state(false);
  let notice = $state(null);

  const base = $derived(`/accounts/${account.id}/service_connections/${connection.id}`);
  const waiting = $derived(connection.status === 'pairing' || connection.status === 'reauthorizing');
  const status = $derived(pairing?.status ?? connection.status);
  const login = $derived(pairing?.login ?? {});
  const qrCode = $derived(pairing?.qr?.code ?? null);
  const qrExpiresAt = $derived(pairing?.qr?.expires_at ?? null);
  const secondsLeft = $derived(qrExpiresAt ? secondsUntil(qrExpiresAt, now) : 0);
  const errorText = $derived(loginErrorMessage(login));
  const askingPassword = $derived(status === 'pairing' && login.step === 'password');

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
      return false;
    }
    if (!response.ok) return true;
    const json = await response.json();
    pairing = json;
    if (json.status === 'pairing' || json.status === 'reauthorizing') return true;
    router.reload();
    return false;
  }

  $effect(() => {
    if (!waiting) return;
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
    if (!qrExpiresAt) return;
    now = Date.now();
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  $effect(() => {
    const code = qrCode;
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

  async function act(path) {
    busy = true;
    notice = null;
    const result = await postLoginJson(`${base}/login/${path}`);
    busy = false;
    if (result.ok) {
      pairing = {
        status: result.body.status,
        qr: null,
        login: result.body.login || {},
        generation: result.body.generation,
      };
    } else {
      notice = { tone: 'error', text: result.body.error || 'Something went wrong. Try again.' };
    }
  }

  async function submitPassword(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const input = form.elements.namedItem('password');
    const password = input.value;
    input.value = '';
    busy = true;
    notice = null;
    // The attempt this page is showing: a password never joins a newer one.
    const result = await postLoginJson(`${base}/login/password`, { password, generation: pairing?.generation });
    busy = false;
    input.value = '';
    notice = passwordOutcomeMessage(result.ok ? result.body : { error: result.body.error });
  }
</script>

<section class="space-y-4 rounded-lg border bg-muted/30 p-4" data-testid="telegram-login" aria-live="polite">
  {#if notOwner}
    <p class="text-sm text-muted-foreground">Waiting for the person who connected it to sign in.</p>
  {:else if !pairing}
    <p class="text-sm text-muted-foreground">Checking the sign-in.</p>
  {:else}
    {#if status === 'reauthorizing'}
      <p class="text-sm">Telegram signed this session out. Sign in again so residents can keep reading these chats.</p>
    {:else if askingPassword}
      <form class="max-w-sm space-y-3" onsubmit={submitPassword} autocomplete="on">
        <p class="text-sm">This account has a two-step verification password. Enter it to finish signing in.</p>
        <label class="block space-y-1 text-sm">
          <span class="font-medium">Telegram password</span>
          <input
            name="password"
            type="password"
            autocomplete="current-password"
            required
            disabled={busy}
            class="block w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </label>
        {#if login.hint}
          <p class="text-sm text-muted-foreground">Hint: {login.hint}</p>
        {/if}
        <Button type="submit" size="sm" disabled={busy}>Sign in</Button>
      </form>
    {:else if qrCode}
      <div class="flex flex-col gap-4 sm:flex-row sm:items-start">
        <div class="w-fit shrink-0 rounded-lg bg-white p-2">
          {#if qrImage}
            <img
              src={qrImage}
              alt="Telegram sign-in QR code"
              width="200"
              height="200"
              class={`size-[200px] ${secondsLeft === 0 ? 'opacity-30' : ''}`} />
          {:else}
            <div class="size-[200px]"></div>
          {/if}
        </div>
        <div class="min-w-0 space-y-2 text-sm">
          <p class="font-medium">Scan this code with Telegram on your phone.</p>
          <ol class="list-decimal space-y-1 pl-5 text-muted-foreground">
            <li>Open Telegram and go to Settings, then Devices.</li>
            <li>Tap Link Desktop Device.</li>
            <li>Point the camera at this code.</li>
          </ol>
          <p class="text-muted-foreground" data-testid="telegram-qr-countdown">
            {secondsLeft > 0
              ? `This code expires in ${formatCountdown(secondsLeft)}. A new one appears by itself.`
              : 'This code expired. Waiting for a new one.'}
          </p>
        </div>
      </div>
    {:else if !errorText}
      <p class="text-sm text-muted-foreground">Waiting for a sign-in code from Telegram.</p>
    {/if}

    {#if errorText && !notice}
      <p class="text-sm text-destructive" role="alert">{errorText}</p>
    {/if}
    {#if notice}
      <p class={`text-sm ${notice.tone === 'ok' ? 'text-emerald-700' : 'text-destructive'}`} role="status">
        {notice.text}
      </p>
    {/if}

    <div class="flex flex-wrap gap-2">
      <Button type="button" variant="outline" size="sm" disabled={busy} onclick={() => act('restart')}>
        Restart sign-in
      </Button>
      {#if status === 'pairing' && login.error !== 'cancelled'}
        <Button type="button" variant="ghost" size="sm" disabled={busy} onclick={() => act('cancel')}>Cancel</Button>
      {/if}
    </div>
  {/if}
</section>
