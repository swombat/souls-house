<script>
  import { Button } from '$lib/components/shadcn/button';
  import { formatCountdown, postLoginJson } from '$lib/telegram-connection';
  import { formatPhoneCode, phoneFailureMessage } from '$lib/whatsapp-pairing';

  // WhatsApp's "Link with phone number instead", for the owner on the phone
  // WhatsApp is on (it cannot scan a QR on its own screen): the number,
  // then the 8-character code to type into WhatsApp. The number is sent
  // once and kept nowhere, not even here; the code comes from the pairing
  // endpoint the parent polls. begin(): called as the number is sent; it
  // returns the function that takes the pairing state the server answers
  // with, unless the owner has changed something since (the parent drops
  // anything older than its latest change).
  let {
    base,
    attempt,
    phase,
    phoneCode = null,
    failure = null,
    secondsLeft = 0,
    busy = $bindable(false),
    begin = () => () => {},
    onstale = () => {},
    onnotice = () => {},
  } = $props();

  let changingNumber = $state(false);
  let copied = $state(false);

  const code = $derived(formatPhoneCode(phoneCode?.code));
  const askingNumber = $derived(phase === 'number' || phase === 'failed' || changingNumber);

  async function submit(event) {
    event.preventDefault();
    const input = event.currentTarget.elements.namedItem('phone');
    busy = true;
    onnotice(null);
    const commit = begin();
    // The attempt this page is showing: a number never joins a newer one.
    const result = await postLoginJson(`${base}/pairing/phone`, { phone: input.value.trim(), attempt });
    busy = false;
    if (result.ok) {
      input.value = '';
      changingNumber = false;
      commit(result.body);
    } else {
      // Refused as another attempt's (restarted meanwhile): refresh the
      // attempt so that sending again joins the current one.
      if (result.status === 409) onstale();
      onnotice(result.body.error || 'Something went wrong. Try again.');
    }
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(code);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      copied = false;
    }
  }
</script>

<div class="space-y-3 text-sm" data-testid="whatsapp-phone-pairing">
  {#if askingNumber}
    {#if phase === 'failed' && !changingNumber}
      <p class="text-destructive" role="alert" data-testid="whatsapp-phone-failure">{phoneFailureMessage(failure)}</p>
    {/if}
    <form class="max-w-sm space-y-3" onsubmit={submit} data-testid="whatsapp-phone-form">
      <p>Link with your phone number: WhatsApp gives you a code to type in on your phone, no scanning needed.</p>
      <label class="block space-y-1">
        <span class="font-medium">Phone number</span>
        <input
          name="phone"
          type="tel"
          inputmode="tel"
          autocomplete="tel"
          placeholder="+44 7700 900123"
          maxlength="40"
          required
          disabled={busy}
          aria-describedby="whatsapp-phone-format"
          class="block w-full rounded-md border bg-background px-3 py-2 text-sm" />
      </label>
      <p id="whatsapp-phone-format" class="text-muted-foreground">
        The number WhatsApp is on, in international format: + and the country code, then the number.
      </p>
      <Button type="submit" size="sm" disabled={busy}>Get a code</Button>
    </form>
  {:else if phase === 'requesting'}
    <p class="text-muted-foreground" data-testid="whatsapp-phone-requesting">Asking WhatsApp for a code.</p>
  {:else if phase === 'code' || (phase === 'expired' && code)}
    <div class="space-y-3">
      <p class="font-medium">Enter this code in WhatsApp on your phone.</p>
      <div class="flex flex-wrap items-center gap-3">
        <p
          class={`font-mono text-3xl font-semibold tracking-widest ${phase === 'code' ? '' : 'line-through opacity-40'}`}
          aria-label={`Pairing code ${code}`}
          data-testid="whatsapp-phone-code">
          {code}
        </p>
        {#if phase === 'code' && typeof navigator !== 'undefined' && navigator.clipboard}
          <Button type="button" variant="outline" size="sm" onclick={copy}>{copied ? 'Copied' : 'Copy code'}</Button>
        {/if}
      </div>
      <ol class="list-decimal space-y-1 pl-5 text-muted-foreground" data-testid="whatsapp-phone-steps">
        <li>Open WhatsApp and go to Settings.</li>
        <li>Tap Linked devices, then Link a device.</li>
        <li>Tap “Link with phone number instead”.</li>
        <li>Enter the code {code}.</li>
      </ol>
      <p class={phase === 'code' ? 'text-muted-foreground' : 'text-destructive'} data-testid="whatsapp-phone-countdown">
        {#if phase === 'code'}
          This code expires in {formatCountdown(secondsLeft)}.
        {:else}
          This code expired. Restart pairing for a new one.
        {/if}
      </p>
      {#if phase === 'code'}
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={busy}
          onclick={() => {
            onnotice(null);
            changingNumber = true;
          }}>
          Use a different number
        </Button>
      {/if}
    </div>
  {:else if phase === 'expired'}
    <p class="text-destructive" data-testid="whatsapp-phone-countdown">
      This code expired. Restart pairing for a new one.
    </p>
  {/if}
</div>
