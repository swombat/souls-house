<script>
  // The quote for an item order: in an account with a live Stripe
  // subscription the new resident is added to that subscription, charged on
  // the next bill and nothing today. The owner confirms the quote here;
  // confirming calls confirmAddToBill, and the outcome goes back through
  // onconfirmed or onconfirmfailed. When the house answers that the price
  // changed, the new quote replaces the shown one and must be confirmed again.
  import { Button } from '$lib/components/shadcn/button';
  import { confirmAddToBill } from '$lib/paid-birth';

  let {
    // The order as paid-birth returns it (payment, with payment.item_quote).
    itemPayment,
    name = 'your resident',
    busy = false,
    onphase = () => {},
    onconfirmed = () => {},
    onconfirmfailed = () => {},
    ondismiss = () => {},
  } = $props();

  // The quote on screen. It starts as the order's and is replaced when the
  // house answers that the price changed.
  let shownPayment = $state(null);
  let priceChanged = $state(false);
  let adding = $state(false);
  $effect(() => {
    shownPayment = itemPayment;
    priceChanged = false;
  });
  let quote = $derived(shownPayment?.item_quote || null);
  let residentName = $derived(shownPayment?.order?.resident_name || name);

  // As the Billing page shows Stripe's amounts.
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
</script>

{#if quote}
  <div class="space-y-3 rounded-lg border border-primary/40 bg-primary/5 p-4 text-sm" data-testid="birth-add-confirm">
    {#if priceChanged}
      <p class="font-medium" data-testid="birth-add-changed">
        The price changed since it was shown. Here is the new one; nothing was charged.
      </p>
    {/if}
    <p>
      Nothing is charged today. Your next bill{quote.next_at ? `, on ${quote.next_at},` : ''} goes up by about
      {cents(quote.added_cents, quote.currency)} for {residentName}: the rest of this period and the next month. That
      bill comes to about {cents(quote.next_total_cents, quote.currency)} in all, including anything else already due on
      it. After that, the account pays about
      {cents(quote.recurring_cents, quote.currency)} a month for all its residents together. These are Stripe's totals, with
      tax and discounts in.
    </p>
    <div class="flex gap-2">
      <Button size="sm" onclick={confirmAdd} disabled={adding || busy}>
        {adding ? 'Adding…' : `Create ${residentName} and add to the account's bill`}
      </Button>
      <Button size="sm" variant="outline" onclick={ondismiss} disabled={adding || busy}>Not now</Button>
    </div>
  </div>
{/if}
