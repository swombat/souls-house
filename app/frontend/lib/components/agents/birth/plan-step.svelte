<script>
  // The creation wizard's last step in an account that pays per resident:
  // choose the resident's size, and the card it is paid with. Stripe's own
  // embedded form takes a new card; nothing is charged until the resident is
  // created with the button below this step. The account's plan is not chosen
  // here: one line names it and links to Billing. When the account's free 14
  // days apply (trial.eligible, a small resident at the standard price), no
  // card is asked for.
  //
  // In an account with a live Stripe subscription a new resident is added to
  // that subscription instead of being paid by card. The page then passes the
  // order (payment, with its item_quote) and this step shows the quote in a
  // panel; confirming it calls confirmAddToBill, and the outcome goes back to
  // the page through onconfirmed or onconfirmfailed. Nothing is charged today.
  import { onDestroy } from 'svelte';
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { Badge } from '$lib/components/shadcn/badge';
  import { CreditCard, LockSimple } from 'phosphor-svelte';
  import SizePicker from './size-picker.svelte';
  import { sizeOf, trialApplies, usd } from '$lib/pricing';
  import { loadStripe, postJson, createEmbeddedCheckout } from '$lib/stripe';
  import { confirmAddToBill } from '$lib/paid-birth';

  let {
    billing,
    residentName = '',
    tier = $bindable(null),
    paymentMethod = $bindable(null),
    payError = null,
    // The money was taken but the house hasn't finished: no decline wording.
    payPaid = false,
    // Why this draft can't be paid for on the chosen plan, if it can't.
    blocked = null,
    busy = false,
    // The account's free 14 days, { eligible, days } from the server.
    trial = null,
    // The account's Billing tab, where its plan is changed.
    billingUrl = null,
    // An item order waiting for the owner: the order as paid-birth returns it
    // (payment, with payment.item_quote), or null.
    itemPayment = null,
    onphase = () => {},
    onconfirmed = () => {},
    onconfirmfailed = () => {},
    // The owner chose "Not now": the order stays and can be resumed.
    ondismiss = () => {},
    // The wizard's pay state for an item order, so a failure reads as "not
    // added yet" and never as a declined card.
    deferred = false,
  } = $props();

  // Offers (a plan at a rate: standard, or at cost when the account holds a
  // code for it); older props carry only tiers, which are the standard offers.
  let tiers = $derived(billing.offers?.length ? billing.offers : billing.tiers || []);
  let chosen = $derived(tiers.find((candidate) => candidate.id === tier) || null);
  let atCost = $derived(chosen?.rate === 'at_cost');
  let name = $derived(residentName.trim() || 'your resident');
  let free = $derived(trialApplies(trial, chosen));
  let trialDays = $derived(trial?.days ?? 14);
  // The account's plan, if the server sent it (billing.account_plan).
  let accountPlan = $derived(
    billing.account_plan
      ? (billing.account_plans || []).find((plan) => plan.id === billing.account_plan.id) || null
      : null
  );
  // Partners and Colleagues are never part of the free 14 days.
  let accountPlanPaid = $derived(Number(accountPlan?.monthly_usd) > 0);

  let cardFormOpen = $state(false);
  let cardFormLoading = $state(false);
  let cardError = $state(null);
  let cardContainer = $state(null);
  let checkout = null;

  // The quote on screen. It starts as the order's and is replaced when the house
  // answers that the price changed.
  let shownPayment = $state(null);
  let priceChanged = $state(false);
  let adding = $state(false);
  $effect(() => {
    shownPayment = itemPayment;
    priceChanged = false;
  });
  let quote = $derived(shownPayment?.item_quote || null);

  function cents(amount, currency) {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: (currency || 'usd').toUpperCase() }).format(
      (amount ?? 0) / 100
    );
  }

  async function confirmAdd() {
    adding = true;
    try {
      onconfirmed(await confirmAddToBill({ payment: shownPayment, onPhase: onphase }));
    } catch (error) {
      if (error.itemQuote) {
        shownPayment = error.payment;
        priceChanged = true;
      }
      onconfirmfailed(error);
    } finally {
      adding = false;
    }
  }

  // Small, at the standard price, unless the draft already chose.
  if (!tier && tiers.length > 0) {
    tier = (
      tiers.find((option) => sizeOf(option) === 'small' && (option.rate ?? 'standard') === 'standard') || tiers[0]
    ).id;
  }

  function brandName(brand) {
    const names = { visa: 'Visa', mastercard: 'Mastercard', amex: 'American Express', discover: 'Discover' };
    return names[brand] || (brand ? brand[0].toUpperCase() + brand.slice(1) : 'Card');
  }

  function expiry(method) {
    return `${String(method.exp_month).padStart(2, '0')}/${String(method.exp_year).slice(-2)}`;
  }

  function closeCardForm() {
    checkout?.destroy();
    checkout = null;
    cardFormOpen = false;
  }

  async function openCardForm() {
    cardError = null;
    cardFormOpen = true;
    cardFormLoading = true;
    try {
      const stripe = await loadStripe(billing.publishable_key);
      const { session_id: sessionId, client_secret: clientSecret } = await postJson(billing.card_setup_url);
      checkout = await createEmbeddedCheckout(stripe, {
        fetchClientSecret: async () => clientSecret,
        onComplete: async () => {
          try {
            const saved = await postJson(billing.card_setup_complete_url, { session_id: sessionId });
            paymentMethod = saved.payment_method;
            closeCardForm();
          } catch (error) {
            cardError = error.message;
          }
        },
      });
      checkout.mount(cardContainer);
    } catch (error) {
      cardError = error.message;
      cardFormOpen = false;
    } finally {
      cardFormLoading = false;
    }
  }

  // A free trial asks for no card: Stripe's card form never stays open for one.
  $effect(() => {
    if (free) closeCardForm();
  });

  onDestroy(() => checkout?.destroy());
</script>

<CardHeader>
  <CardTitle>A computer for {name}</CardTitle>
  <CardDescription>
    {#if atCost}
      Each resident is paid for by the size of the computer it lives on. At cost, it pays for that computer and nothing
      more: {name} thinks with a model subscription or key you connect.
    {:else}
      Each resident is paid for by the size of the computer it lives on. Small is right for most residents.
    {/if}
  </CardDescription>
</CardHeader>
<CardContent class="space-y-8">
  {#if !billing.can_pay}
    <Alert data-testid="plan-owner-only">
      <LockSimple class="size-4" />
      <AlertTitle>The account's owner pays for new residents</AlertTitle>
      <AlertDescription>
        Your draft is saved in this browser. Ask the owner of this account to create {name}.
      </AlertDescription>
    </Alert>
  {:else}
    <SizePicker options={tiers} bind:tier {busy} />

    <p class="text-sm text-muted-foreground" data-testid="plan-account-plan">
      {#if accountPlan && free && accountPlanPaid}
        This account is on {accountPlan.name}, which is charged as usual. The free {trialDays} days are for {name} only.
      {:else if accountPlan}
        This account is on {accountPlan.name}.
      {:else}
        The account's plan decides who else can join it and what its residents can do.
      {/if}
      {#if billingUrl}
        <a class="underline underline-offset-4" href={billingUrl}>Change it on the Billing tab</a>.
      {/if}
    </p>

    {#if !free}
      <section class="space-y-3" aria-labelledby="paying-with">
        <div class="flex items-center justify-between">
          <h3 id="paying-with" class="text-sm font-medium">Paying with</h3>
          {#if billing.test_mode}
            <Badge variant="outline" data-testid="plan-test-mode">Test mode · card 4242 4242 4242 4242</Badge>
          {/if}
        </div>

        {#if paymentMethod && !cardFormOpen}
          <div class="flex items-center justify-between gap-4 rounded-lg border p-4" data-testid="plan-card-on-file">
            <div class="flex items-center gap-3">
              <CreditCard class="size-6 text-muted-foreground" />
              <div>
                <p class="text-sm font-medium">{brandName(paymentMethod.brand)} ending {paymentMethod.last4}</p>
                <p class="text-xs text-muted-foreground">Expires {expiry(paymentMethod)}</p>
              </div>
            </div>
            <Button type="button" variant="ghost" size="sm" onclick={openCardForm} disabled={busy}>
              Use a different card
            </Button>
          </div>
        {:else if !cardFormOpen}
          <div class="rounded-lg border border-dashed p-4 text-sm">
            {#if billing.payment_method_error}
              <p class="mb-3 text-muted-foreground">We couldn't reach Stripe to show the card on file.</p>
            {:else}
              <p class="mb-3 text-muted-foreground">
                Add the card this account pays with. It's saved for its residents' plans and isn't charged until you
                create {name}.
              </p>
            {/if}
            <Button type="button" variant="outline" onclick={openCardForm} disabled={busy}>
              <CreditCard class="mr-2 size-4" />
              Add a card
            </Button>
          </div>
        {/if}

        {#if cardFormOpen}
          <div class="space-y-2">
            {#if cardFormLoading}
              <p class="text-sm text-muted-foreground">Opening Stripe's secure card form…</p>
            {/if}
            <!-- Stripe mounts only into an element with no child nodes: keep this one empty. -->
            <div class="overflow-hidden rounded-lg border" bind:this={cardContainer} data-testid="plan-card-form"></div>
            <div class="flex items-center justify-between text-xs text-muted-foreground">
              <span class="flex items-center gap-1"
                ><LockSimple class="size-3.5" />Your card goes to Stripe. The house never sees it.</span>
              {#if paymentMethod}
                <button type="button" class="underline underline-offset-4" onclick={closeCardForm}
                  >Keep the saved card</button>
              {/if}
            </div>
          </div>
        {/if}

        {#if cardError}
          <p class="text-sm text-destructive" role="alert">{cardError}</p>
        {/if}
      </section>
    {/if}

    {#if chosen && free}
      <section class="space-y-2 rounded-lg bg-muted/40 p-4 text-sm leading-6" data-testid="plan-terms">
        <p class="font-medium" data-testid="plan-trial">Free for {trialDays} days. No card asked for.</p>
        <p>
          To keep {name} awake after that, add a card from the account's Billing tab: then it is {usd(
            chosen.monthly_usd
          )} + VAT a month. With no card, {name} goes to sleep on day {trialDays}. Nothing is deleted.
        </p>
      </section>
    {:else if chosen}
      <section class="space-y-2 rounded-lg bg-muted/40 p-4 text-sm leading-6" data-testid="plan-terms">
        <p>
          <span class="font-medium">Today:</span>
          {usd(chosen.monthly_usd)} + VAT for {name}'s first month.
          <span class="font-medium">Then</span>
          {usd(chosen.monthly_usd)} + VAT each month until you cancel.
        </p>
        {#if atCost}
          <p data-testid="plan-at-cost-terms">
            At cost: this pays for {name}'s own server and what comes with it, and includes no house-model allowance.
            {name} runs on a model subscription or key you connect.
          </p>
        {/if}
        <p class="text-muted-foreground">
          Cancel any time from the account's Billing tab. Not what you hoped? Write to
          <a class="underline underline-offset-4" href="mailto:{billing.contact_email}">{billing.contact_email}</a> within
          30 days for a full refund.
        </p>
      </section>
    {/if}

    {#if blocked}
      <Alert variant="destructive" data-testid="plan-blocked">
        <AlertTitle>This choice doesn't fit the draft</AlertTitle>
        <AlertDescription>{blocked}</AlertDescription>
      </Alert>
    {/if}

    {#if payError}
      <Alert variant="destructive" data-testid="plan-pay-error">
        {#if free && !payPaid}
          <AlertTitle>The free trial didn't start</AlertTitle>
          <AlertDescription>{payError} Nothing was created.</AlertDescription>
        {:else if deferred}
          <AlertTitle>Not added yet</AlertTitle>
          <AlertDescription>{payError}</AlertDescription>
        {:else if payPaid}
          <AlertTitle>Almost there</AlertTitle>
          <AlertDescription>{payError}</AlertDescription>
        {:else}
          <AlertTitle>The payment didn't go through</AlertTitle>
          <AlertDescription>
            {payError} Nothing was created. You can try again, or use a different card.
          </AlertDescription>
        {/if}
      </Alert>
    {/if}

    {#if quote}
      <div
        class="space-y-3 rounded-lg border border-primary/40 bg-primary/5 p-4 text-sm"
        data-testid="birth-add-confirm">
        {#if priceChanged}
          <p class="font-medium" data-testid="birth-add-changed">
            The price changed since it was shown. Here is the new one; nothing was charged.
          </p>
        {/if}
        <p>
          Nothing is charged today. Your next bill{quote.next_at ? `, on ${quote.next_at},` : ''} goes up by about
          {cents(quote.added_cents, quote.currency)} for {shownPayment.order?.resident_name || name}: the rest of this
          period and the next month. That bill comes to about {cents(quote.next_total_cents, quote.currency)} in all, including
          anything else already due on it. After that, the account pays about
          {cents(quote.recurring_cents, quote.currency)} a month for all its residents together. These are Stripe's totals,
          with tax and discounts in.
        </p>
        <div class="flex gap-2">
          <Button size="sm" onclick={confirmAdd} disabled={adding || busy}>
            {adding ? 'Adding…' : `Create ${shownPayment.order?.resident_name || name} and add to the account's bill`}
          </Button>
          <Button size="sm" variant="outline" onclick={ondismiss} disabled={adding || busy}>Not now</Button>
        </div>
      </div>
    {/if}
  {/if}
</CardContent>
