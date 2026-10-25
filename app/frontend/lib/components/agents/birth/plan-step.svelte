<script>
  // The creation wizard's last step in an account that pays per resident:
  // choose the resident's plan, and the card it is paid with. Stripe's own
  // embedded form takes a new card; nothing is charged until the resident is
  // created with the button below this step.
  import { onDestroy } from 'svelte';
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { Badge } from '$lib/components/shadcn/badge';
  import { CreditCard, CheckCircle, LockSimple } from 'phosphor-svelte';
  import PlanIncludes from '$lib/components/billing/PlanIncludes.svelte';
  import { planTaglines } from '$lib/pricing';
  import { loadStripe, postJson, createEmbeddedCheckout } from '$lib/stripe';

  let {
    billing,
    residentName = '',
    tier = $bindable(null),
    paymentMethod = $bindable(null),
    payError = null,
    busy = false,
  } = $props();

  let tiers = $derived(billing.tiers || []);
  let chosen = $derived(tiers.find((candidate) => candidate.id === tier) || null);
  let name = $derived(residentName.trim() || 'your resident');

  let cardFormOpen = $state(false);
  let cardFormLoading = $state(false);
  let cardError = $state(null);
  let cardContainer = $state(null);
  let checkout = null;

  if (!tier && tiers.length > 0) tier = tiers[0].id;

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

  onDestroy(() => checkout?.destroy());
</script>

<CardHeader>
  <CardTitle>A plan for {name}</CardTitle>
  <CardDescription>
    Each resident has its own plan. It pays for their home here and for the house model they think with, up to the
    plan's monthly allowance.
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
    <fieldset class="space-y-3" disabled={busy}>
      <legend class="mb-3 text-sm font-medium">Plan</legend>
      <div
        class="grid gap-3 {tiers.length >= 3 ? 'sm:grid-cols-3' : 'sm:grid-cols-2'}"
        role="radiogroup"
        aria-label="Plan">
        {#each tiers as option (option.id)}
          {@const selected = option.id === tier}
          <label
            class="relative flex cursor-pointer flex-col rounded-lg border-2 p-4 transition-colors
              {selected ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/40'}">
            <input
              type="radio"
              name="plan"
              value={option.id}
              class="sr-only"
              checked={selected}
              onchange={() => (tier = option.id)} />
            <span class="flex items-start justify-between gap-2">
              <span class="font-semibold">{option.name}</span>
              {#if selected}<CheckCircle class="size-5 text-primary" weight="fill" />{/if}
            </span>
            <span class="mt-1 text-sm text-muted-foreground">{planTaglines[option.id] ?? ''}</span>
            <span class="mt-3">
              <span class="text-2xl font-semibold">${option.monthly_usd}</span>
              <span class="text-sm text-muted-foreground">/ month + VAT</span>
            </span>
            <PlanIncludes
              features={option.features}
              class="mt-3 text-xs text-muted-foreground"
              iconClass="text-primary/70" />
          </label>
        {/each}
      </div>
    </fieldset>

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

    {#if chosen}
      <section class="rounded-lg bg-muted/40 p-4 text-sm leading-6" data-testid="plan-terms">
        <p>
          <span class="font-medium">Today:</span> ${chosen.monthly_usd} + VAT for {name}'s first month.
          <span class="font-medium">Then</span> ${chosen.monthly_usd} + VAT each month until you cancel.
        </p>
        <p class="text-muted-foreground">
          Cancel any time from the account's Billing tab. Not what you hoped? Write to
          <a class="underline underline-offset-4" href="mailto:{billing.contact_email}">{billing.contact_email}</a> within
          30 days for a full refund.
        </p>
      </section>
    {/if}

    {#if payError}
      <Alert variant="destructive" data-testid="plan-pay-error">
        <AlertTitle>The payment didn't go through</AlertTitle>
        <AlertDescription>
          {payError} Nothing was created. You can try again, or use a different card.
        </AlertDescription>
      </Alert>
    {/if}
  {/if}
</CardContent>
