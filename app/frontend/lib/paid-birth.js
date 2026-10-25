// The wizard's last step in an account that pays per resident: start the
// plan for the drafted resident, pay its first month with the account's saved
// card (Stripe.js handles any bank check), then wait for the house to say the
// resident is born. Nothing is born before the payment clears.
import { loadStripe, postJson } from '$lib/stripe';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Returns { redirectTo } once born, or { redirectTo: null, order } when Stripe
// is still confirming. Throws an Error with .payment (to pay again) on a
// decline or a bank check that wasn't completed.
export async function payForResident({ billing, agent, tier, providerKey, onPhase = () => {}, pollMs = 1500 }) {
  const stripe = await loadStripe(billing.publishable_key);
  onPhase('starting');
  const payment = await postJson(billing.birth_orders_url, {
    agent,
    tier,
    ...(providerKey ? { provider_key: providerKey } : {}),
  });
  return settle({ stripe, payment, onPhase, pollMs });
}

// Pay an order's open first invoice again, with the card now on the account.
export async function payAgain({ billing, payment, onPhase = () => {}, pollMs = 1500 }) {
  const stripe = await loadStripe(billing.publishable_key);
  onPhase('starting');
  const fresh = await postJson(payment.payment_url);
  return settle({ stripe, payment: fresh, onPhase, pollMs });
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

  onPhase('confirming');
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const confirmation = await postJson(payment.confirm_url).catch((error) => {
      if (error.data?.order) return error.data;
      throw error;
    });
    if (confirmation.redirect_to) return { redirectTo: confirmation.redirect_to, order: confirmation.order };
    if (confirmation.order?.state === 'failed') {
      throw new Error(
        'Your payment went through, but the resident could not be started. The house has been told and will put it right.'
      );
    }
    await sleep(pollMs);
  }
  return { redirectTo: null, order: payment.order };
}
