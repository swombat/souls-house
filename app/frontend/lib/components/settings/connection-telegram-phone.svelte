<script>
  import { Button } from '$lib/components/shadcn/button';
  import { codeOutcomeMessage, codeSentText, phoneOutcomeMessage, postLoginJson } from '$lib/telegram-connection';

  // The phone-number sign-in for one attempt: the number, then the code
  // Telegram sends. The parent keeps the attempt (its login step and
  // generation) and the notice; this keeps only the number, in memory, to
  // send the code again. Never in page props, history or storage.
  // onlogin(login): the attempt's login step changed. onshowqr: offered
  // when the QR is there to go back to.
  let {
    base,
    generation,
    login = {},
    busy = $bindable(false),
    onlogin = () => {},
    onnotice = () => {},
    onshowqr = null,
  } = $props();

  let changingNumber = $state(false);
  let lastPhone = null;

  const askingCode = $derived(login.step === 'code' && !changingNumber);

  async function sendPhone(phone) {
    const resend = login.step === 'code';
    busy = true;
    onnotice(null);
    // The attempt this page is showing: a number never joins a newer one.
    const result = await postLoginJson(`${base}/login/phone`, { phone, generation });
    busy = false;
    const body = result.ok ? result.body : { error: result.body.error };
    if (body.outcome === 'code_sent') {
      lastPhone = phone;
      changingNumber = false;
      onlogin(body.login || { step: 'code' });
    } else if (body.outcome === 'password_required') {
      onlogin({ step: 'password' });
    }
    onnotice(phoneOutcomeMessage(body, { resend }));
    return body.outcome;
  }

  async function submitPhone(event) {
    event.preventDefault();
    const input = event.currentTarget.elements.namedItem('phone');
    const outcome = await sendPhone(input.value.trim());
    if (outcome === 'code_sent') input.value = '';
  }

  async function sendAgain() {
    if (lastPhone) {
      await sendPhone(lastPhone);
    } else {
      onnotice(null);
      changingNumber = true;
    }
  }

  async function submitCode(event) {
    event.preventDefault();
    const input = event.currentTarget.elements.namedItem('code');
    const code = input.value.trim();
    input.value = '';
    busy = true;
    onnotice(null);
    const result = await postLoginJson(`${base}/login/code`, { code, generation });
    busy = false;
    input.value = '';
    const body = result.ok ? result.body : { error: result.body.error };
    if (body.outcome === 'password_required') {
      lastPhone = null;
      onlogin({ step: 'password' });
    } else if (body.outcome === 'accepted') {
      lastPhone = null;
    }
    onnotice(codeOutcomeMessage(body));
  }
</script>

{#if askingCode}
  <form class="max-w-sm space-y-3" onsubmit={submitCode} data-testid="telegram-code-form">
    <p class="text-sm" data-testid="telegram-code-sent">{codeSentText(login)}</p>
    <label class="block space-y-1 text-sm">
      <span class="font-medium">Login code</span>
      <input
        name="code"
        type="text"
        inputmode="numeric"
        autocomplete="one-time-code"
        maxlength="64"
        required
        disabled={busy}
        class="block w-full rounded-md border bg-background px-3 py-2 text-sm tracking-widest" />
    </label>
    <div class="flex flex-wrap gap-2">
      <Button type="submit" size="sm" disabled={busy}>Sign in</Button>
      <Button type="button" variant="outline" size="sm" disabled={busy} onclick={sendAgain}>Send a new code</Button>
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
    </div>
  </form>
{:else}
  <form class="max-w-sm space-y-3" onsubmit={submitPhone} data-testid="telegram-phone-form">
    <p class="text-sm">
      Sign in with the phone number of your Telegram account. Telegram sends a code to the Telegram app.
    </p>
    <label class="block space-y-1 text-sm">
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
        aria-describedby="telegram-phone-format"
        class="block w-full rounded-md border bg-background px-3 py-2 text-sm" />
    </label>
    <p id="telegram-phone-format" class="text-sm text-muted-foreground">
      International format: + and the country code, then the number.
    </p>
    <div class="flex flex-wrap gap-2">
      <Button type="submit" size="sm" disabled={busy}>Send the code</Button>
      {#if onshowqr && !changingNumber}
        <Button type="button" variant="ghost" size="sm" disabled={busy} onclick={onshowqr}>Show the QR code</Button>
      {/if}
    </div>
  </form>
{/if}
