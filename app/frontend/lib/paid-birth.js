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
import { loadStripe, postJson } from '$lib/stripe';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Returns { redirectTo } once born, or { redirectTo: null, order } when Stripe
// is still confirming.
export async function payForResident({
  billing,
  agent,
  tier,
  rate = 'standard',
  providerKey,
  onPhase = () => {},
  pollMs = 1500,
}) {
  const stripe = await loadStripe(billing.publishable_key);
  onPhase('starting');
  let payment;
  try {
    payment = await postJson(billing.birth_orders_url, {
      agent,
      tier,
      rate,
      ...(providerKey ? { provider_key: providerKey } : {}),
    });
  } catch (error) {
    if (error.data?.payment_url) error.payment = error.data;
    throw error;
  }
  return settle({ stripe, payment, onPhase, pollMs });
}

// Resume an order: pay its open first invoice (with the card now on the
// account), or, if it is already paid, go straight to confirming.
export async function payAgain({ billing, payment, onPhase = () => {}, pollMs = 1500 }) {
  const stripe = await loadStripe(billing.publishable_key);
  onPhase('starting');
  let fresh;
  try {
    fresh = await postJson(payment.payment_url);
  } catch (error) {
    error.payment = payment;
    throw error;
  }
  if (fresh.paid) return confirm({ payment: { ...fresh, paid: true }, onPhase, pollMs });
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
  return confirm({ payment: { ...payment, paid: true }, onPhase, pollMs });
}

async function confirm({ payment, onPhase, pollMs }) {
  onPhase('confirming');
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
          'Your payment went through, but the house could not finish just now. Press the button again to finish: nothing more will be charged.'
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
        'Your payment went through, but the resident could not be started. The house has been told and will put it right.'
      );
      failed.payment = payment;
      throw failed;
    }
    await sleep(pollMs);
  }
  return { redirectTo: null, order: payment.order };
}
