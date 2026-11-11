// The wizard's last step in an account that pays per resident: start the
// plan for the drafted resident, pay its first month with the account's saved
// card (Stripe.js handles any bank check), then wait for the house to say the
// resident is born. Nothing is born before the payment clears.
//
// One order is one creation. Once it exists, every retry resumes it (through
// its payment URL), so a confirmation that fails after paying, or a page
// reload, never starts a second subscription. Errors carry .payment, the
// order to resume, whenever one exists; .payment.paid is true once Stripe has
// taken the money.
//
// The free trial (trial: true) asks for no card here: the order comes back
// with checkout_url, Stripe's own Checkout page, where the trial starts. The
// browser goes there (openCheckout) and Stripe brings it back to the house,
// which creates the resident. Resuming a trial order goes to the same page.
//
// An account that already has a live Stripe subscription pays no first
// invoice by card. The order comes back as an item order, with item_quote (what
// the next bill will be) and confirm_item_url: payForResident and payAgain
// return { itemQuote, payment } and stop, so the owner can read the quote.
// confirmAddToBill then sends the quote's digest, and the resident is added to
// the account's existing subscription. Nothing is charged today, so nothing
// here ever says a payment went through. If the quote changed meanwhile, the
// house sends the new one back (the error carries .itemQuote) and nothing is
// added until the owner confirms that one.
import { loadStripe, postJson } from '$lib/stripe';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isItemOrder = (payment) =>
  payment?.order?.kind === 'item' || Boolean(payment?.item_quote || payment?.confirm_item_url);

// Returns { redirectTo } once born, { redirectTo: null, order } when Stripe
// is still confirming, { checkoutUrl, payment } for a trial, whose browser
// goes to Stripe's Checkout next, or { itemQuote, payment } for an item order
// that waits for confirmAddToBill.
export async function payForResident({
  billing,
  agent,
  tier,
  rate = 'standard',
  trial = false,
  providerKey,
  onPhase = () => {},
  pollMs = 1500,
}) {
  onPhase('starting');
  let payment;
  try {
    payment = await postJson(billing.birth_orders_url, {
      agent,
      tier,
      rate,
      ...(trial ? { trial: true } : {}),
      ...(providerKey ? { provider_key: providerKey } : {}),
    });
  } catch (error) {
    if (error.data?.payment_url) error.payment = error.data;
    throw error;
  }
  if (payment.checkout_url) return { checkoutUrl: payment.checkout_url, payment };
  if (payment.item_quote) return { itemQuote: payment.item_quote, payment };
  // Stripe.js is needed only when a card payment is: not for a trial, and not
  // for an item order.
  let stripe;
  try {
    stripe = await loadStripe(billing.publishable_key);
  } catch (error) {
    error.payment = payment;
    throw error;
  }
  return settle({ stripe, payment, onPhase, pollMs });
}

// Resume an order: pay its open first invoice (with the card now on the
// account), or, if it is already paid, go straight to confirming. A trial
// order whose Checkout is still open returns { checkoutUrl, payment }. An item
// order not yet accepted returns { itemQuote, payment } to be shown again; one
// already accepted goes straight to confirming.
export async function payAgain({ billing, payment, onPhase = () => {}, pollMs = 1500 }) {
  onPhase('starting');
  let fresh;
  try {
    fresh = await postJson(payment.payment_url);
  } catch (error) {
    error.payment = payment;
    throw error;
  }
  if (fresh.paid) return confirm({ payment: { ...fresh, paid: true }, onPhase, pollMs });
  if (fresh.accepted) return confirm({ payment: { ...payment, ...fresh, accepted: true }, onPhase, pollMs });
  if (fresh.item_quote) return { itemQuote: fresh.item_quote, payment: fresh };
  if (fresh.checkout_url) return { checkoutUrl: fresh.checkout_url, payment: fresh };
  return settle({ stripe: await loadStripe(billing.publishable_key), payment: fresh, onPhase, pollMs });
}

// The owner has read the quote: add the resident to the account's
// subscription, then wait for the house to say it is born. Throws an error
// with .itemQuote and .payment (carrying the new quote) when the price changed,
// and otherwise with .payment, the order to resume.
export async function confirmAddToBill({ payment, onPhase = () => {}, pollMs = 1500 }) {
  onPhase('adding');
  try {
    await postJson(payment.confirm_item_url, { digest: payment.item_quote?.digest });
  } catch (error) {
    if (error.data?.item_quote) {
      error.itemQuote = error.data.item_quote;
      error.payment = { ...payment, item_quote: error.data.item_quote };
    } else {
      error.payment = error.data?.payment_url ? { ...payment, ...error.data } : payment;
    }
    throw error;
  }
  return confirm({ payment: { ...payment, accepted: true }, onPhase, pollMs });
}

// Leaves the house for Stripe's Checkout page.
export function openCheckout(url) {
  window.location.assign(url);
}

// Where a trial order kept with a draft stands when the wizard reopens:
// 'done' once Stripe has started the trial (the resident is born, or will be),
// 'gone' when the house refuses it (its Checkout closed: start again), else
// 'open', to resume.
export async function trialOrderState(payment) {
  try {
    return (await postJson(payment.payment_url)).paid ? 'done' : 'open';
  } catch (error) {
    return error.data?.error ? 'gone' : 'open';
  }
}

async function settle({ stripe, payment, onPhase, pollMs }) {
  onPhase('paying');
  const result = await stripe.confirmCardPayment(payment.client_secret, {
    payment_method: payment.payment_method_id,
  });
  const alreadyPaid = result.error?.payment_intent?.status === 'succeeded';
  if (result.error && !alreadyPaid) {
    const error = new Error(result.error.message || 'The payment did not go through.');
    error.payment = payment;
    throw error;
  }
  return confirm({ payment: { ...payment, paid: true }, onPhase, pollMs });
}

async function confirm({ payment, onPhase, pollMs }) {
  onPhase('confirming');
  const item = isItemOrder(payment);
  const nameOf = (order) => order?.resident_name || payment.order?.resident_name || 'The resident';
  let failures = 0;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    let confirmation;
    try {
      confirmation = await postJson(payment.confirm_url);
    } catch (error) {
      if (error.data?.order) {
        confirmation = error.data;
      } else if ((failures += 1) >= 3) {
        const stuck = new Error(
          item
            ? `${nameOf()} is on the account's bill, but the house could not finish creating it just now. Press the button again to finish: nothing more will be added.`
            : 'Your payment went through, but the house could not finish just now. Press the button again to finish: nothing more will be charged.'
        );
        stuck.payment = payment;
        throw stuck;
      } else {
        await sleep(pollMs);
        continue;
      }
    }
    if (confirmation.redirect_to) return { redirectTo: confirmation.redirect_to, order: confirmation.order };
    if (confirmation.order?.state === 'failed') {
      const failed = new Error(
        item
          ? `${nameOf(confirmation.order)} was added to the account's bill but couldn't be created just yet. The house has been told and will put it right; nothing more will be added.`
          : 'Your payment went through, but the resident could not be started. The house has been told and will put it right.'
      );
      failed.payment = payment;
      throw failed;
    }
    await sleep(pollMs);
  }
  return { redirectTo: null, order: payment.order };
}
