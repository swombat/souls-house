import { vi } from 'vitest';

const stripe = { confirmCardPayment: vi.fn() };
const postJson = vi.fn();
vi.mock('$lib/stripe', () => ({ loadStripe: vi.fn(async () => stripe), postJson: (...args) => postJson(...args) }));

const { payForResident, payAgain, confirmAddToBill, trialOrderState } = await import('./paid-birth.js');

const billing = { publishable_key: 'pk_test_1', birth_orders_url: '/accounts/a/birth_orders' };
const started = {
  order: { id: 'o1', tier: 'conversation', state: 'pending' },
  client_secret: 'pi_1_secret',
  payment_method_id: 'pm_visa',
  payment_url: '/accounts/a/birth_orders/o1/payment',
  confirm_url: '/accounts/a/birth_orders/o1/confirm',
};

beforeEach(() => {
  stripe.confirmCardPayment.mockReset();
  postJson.mockReset();
});

test('pays with the saved card, then waits for the house to say the resident is born', async () => {
  postJson
    .mockResolvedValueOnce(started)
    .mockResolvedValueOnce({ order: { state: 'pending' }, redirect_to: null })
    .mockResolvedValueOnce({ order: { state: 'born' }, redirect_to: '/accounts/a/agents/x/onboarding' });
  stripe.confirmCardPayment.mockResolvedValue({ paymentIntent: { status: 'succeeded' } });
  const phases = [];

  const result = await payForResident({
    billing,
    agent: { name: 'Aria' },
    tier: 'conversation',
    onPhase: (phase) => phases.push(phase),
    pollMs: 0,
  });

  expect(postJson).toHaveBeenNthCalledWith(1, '/accounts/a/birth_orders', {
    agent: { name: 'Aria' },
    tier: 'conversation',
    rate: 'standard',
  });
  expect(stripe.confirmCardPayment).toHaveBeenCalledWith('pi_1_secret', { payment_method: 'pm_visa' });
  expect(result.redirectTo).toBe('/accounts/a/agents/x/onboarding');
  expect(phases).toEqual(['starting', 'paying', 'confirming']);
});

test('a decline is thrown with the payment, so it can be paid again', async () => {
  postJson.mockResolvedValueOnce(started);
  stripe.confirmCardPayment.mockResolvedValue({ error: { message: 'Your card was declined.' } });

  const error = await payForResident({ billing, agent: {}, tier: 'conversation', pollMs: 0 }).catch((e) => e);

  expect(error.message).toBe('Your card was declined.');
  expect(error.payment).toBe(started);
  expect(postJson).toHaveBeenCalledTimes(1);
});

test('an invoice already paid is not an error', async () => {
  postJson.mockResolvedValueOnce(started).mockResolvedValueOnce({ order: {}, redirect_to: '/born' });
  stripe.confirmCardPayment.mockResolvedValue({
    error: { code: 'payment_intent_unexpected_state', payment_intent: { status: 'succeeded' } },
  });

  const result = await payForResident({ billing, agent: {}, tier: 'conversation', pollMs: 0 });
  expect(result.redirectTo).toBe('/born');
});

test('when Stripe is slow to confirm, it says so rather than failing', async () => {
  postJson.mockResolvedValueOnce(started);
  for (let i = 0; i < 12; i += 1) postJson.mockResolvedValueOnce({ order: { state: 'pending' }, redirect_to: null });
  stripe.confirmCardPayment.mockResolvedValue({ paymentIntent: { status: 'succeeded' } });

  const result = await payForResident({ billing, agent: {}, tier: 'conversation', pollMs: 0 });
  expect(result.redirectTo).toBeNull();
  expect(result.order).toBe(started.order);
});

test('a confirmation that keeps failing after payment keeps the order, marked paid, to resume', async () => {
  const offline = Object.assign(new Error('Failed to fetch'), {});
  postJson.mockResolvedValueOnce(started).mockRejectedValue(offline);
  stripe.confirmCardPayment.mockResolvedValue({ paymentIntent: { status: 'succeeded' } });

  const error = await payForResident({ billing, agent: {}, tier: 'conversation', pollMs: 0 }).catch((e) => e);

  expect(error.message).toMatch(/payment went through/);
  expect(error.payment.paid).toBe(true);
  expect(error.payment.confirm_url).toBe(started.confirm_url);
});

test('resuming an order that is already paid goes straight to confirming, never paying again', async () => {
  postJson
    .mockResolvedValueOnce({ ...started, client_secret: null, payment_method_id: null, paid: true })
    .mockResolvedValueOnce({ order: { state: 'born' }, redirect_to: '/born' });

  const result = await payAgain({ billing, payment: { ...started, paid: true }, pollMs: 0 });

  expect(postJson).toHaveBeenNthCalledWith(1, started.payment_url);
  expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
  expect(result.redirectTo).toBe('/born');
});

test('an uncertain start keeps the order it made, so a retry resumes it', async () => {
  const uncertain = Object.assign(new Error("Stripe didn't answer in time."), {
    data: {
      error: "Stripe didn't answer in time.",
      order: started.order,
      payment_url: started.payment_url,
      confirm_url: started.confirm_url,
    },
  });
  postJson.mockRejectedValueOnce(uncertain);

  const error = await payForResident({ billing, agent: {}, tier: 'conversation', pollMs: 0 }).catch((e) => e);

  expect(error.payment.payment_url).toBe(started.payment_url);
  expect(error.payment.paid).toBeUndefined();
  expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
});

describe('the free trial', () => {
  const trialStarted = {
    ...started,
    order: { ...started.order, trial: true },
    client_secret: null,
    payment_method_id: null,
    checkout_url: 'https://checkout.stripe.com/c/pay/cs_test_1',
  };

  test('asks for the trial and hands back Stripe Checkout, with no card payment', async () => {
    postJson.mockResolvedValueOnce(trialStarted);
    const phases = [];

    const result = await payForResident({
      billing,
      agent: { name: 'Aria' },
      tier: 'conversation',
      trial: true,
      onPhase: (phase) => phases.push(phase),
      pollMs: 0,
    });

    expect(postJson).toHaveBeenCalledTimes(1);
    expect(postJson).toHaveBeenCalledWith('/accounts/a/birth_orders', {
      agent: { name: 'Aria' },
      tier: 'conversation',
      rate: 'standard',
      trial: true,
    });
    expect(result).toEqual({ checkoutUrl: trialStarted.checkout_url, payment: trialStarted });
    expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
    expect(phases).toEqual(['starting']);
  });

  test('a paid order never sends trial', async () => {
    postJson.mockResolvedValueOnce(started).mockResolvedValueOnce({ order: {}, redirect_to: '/born' });
    stripe.confirmCardPayment.mockResolvedValue({ paymentIntent: { status: 'succeeded' } });

    await payForResident({ billing, agent: {}, tier: 'life', pollMs: 0 });

    expect(postJson.mock.calls[0][1]).not.toHaveProperty('trial');
  });

  test('a refusal is thrown with its message, and nothing is paid', async () => {
    postJson.mockRejectedValueOnce(
      Object.assign(new Error('This account has already had its free trial.'), {
        data: { error: 'This account has already had its free trial.' },
      })
    );

    const error = await payForResident({ billing, agent: {}, tier: 'conversation', trial: true }).catch((e) => e);

    expect(error.message).toBe('This account has already had its free trial.');
    expect(error.payment).toBeUndefined();
    expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
  });

  test('resuming a trial order whose Checkout is open goes back to it', async () => {
    postJson.mockResolvedValueOnce({ ...trialStarted });

    const result = await payAgain({ billing, payment: trialStarted, pollMs: 0 });

    expect(postJson).toHaveBeenCalledWith(trialStarted.payment_url);
    expect(result.checkoutUrl).toBe(trialStarted.checkout_url);
    expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
  });

  test('resuming a trial Stripe has already started confirms the resident', async () => {
    postJson
      .mockResolvedValueOnce({ ...trialStarted, checkout_url: undefined, paid: true })
      .mockResolvedValueOnce({ order: { state: 'born' }, redirect_to: '/born' });

    const result = await payAgain({ billing, payment: trialStarted, pollMs: 0 });

    expect(result.redirectTo).toBe('/born');
    expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
  });

  test('a trial order kept with a draft is done, open or gone', async () => {
    postJson.mockResolvedValueOnce({ ...trialStarted, paid: true });
    expect(await trialOrderState(trialStarted)).toBe('done');
    postJson.mockResolvedValueOnce(trialStarted);
    expect(await trialOrderState(trialStarted)).toBe('open');
    postJson.mockRejectedValueOnce(Object.assign(new Error('closed'), { data: { error: 'closed' } }));
    expect(await trialOrderState(trialStarted)).toBe('gone');
    postJson.mockRejectedValueOnce(new Error('Failed to fetch'));
    expect(await trialOrderState(trialStarted)).toBe('open');
  });
});

describe('an item order on an account with a live subscription', () => {
  const quote = {
    added_cents: 1200,
    next_total_cents: 3400,
    recurring_cents: 2200,
    currency: 'usd',
    next_at: '2026-12-01',
    digest: 'd1',
  };
  const itemOrder = {
    order: { id: 'o2', kind: 'item', state: 'pending', resident_name: 'Aria' },
    item_quote: quote,
    confirm_item_url: '/accounts/a/birth_orders/o2/confirm_item',
    payment_url: '/accounts/a/birth_orders/o2/payment',
    confirm_url: '/accounts/a/birth_orders/o2/confirm',
    client_secret: null,
    payment_method_id: null,
  };

  test('hands back the quote, and never loads Stripe or pays', async () => {
    const { loadStripe } = await import('$lib/stripe');
    loadStripe.mockClear();
    postJson.mockResolvedValueOnce(itemOrder);

    const result = await payForResident({ billing, agent: { name: 'Aria' }, tier: 'conversation', pollMs: 0 });

    expect(result).toEqual({ itemQuote: quote, payment: itemOrder });
    expect(loadStripe).not.toHaveBeenCalled();
    expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
    expect(postJson).toHaveBeenCalledTimes(1);
  });

  test('confirming sends the digest, then polls the confirm url until born', async () => {
    postJson
      .mockResolvedValueOnce({ order: itemOrder.order, accepted: true })
      .mockResolvedValueOnce({ order: { state: 'pending' }, redirect_to: null })
      .mockResolvedValueOnce({ order: { state: 'born' }, redirect_to: '/accounts/a/agents/aria/onboarding' });
    const phases = [];

    const result = await confirmAddToBill({ payment: itemOrder, onPhase: (p) => phases.push(p), pollMs: 0 });

    expect(postJson).toHaveBeenNthCalledWith(1, itemOrder.confirm_item_url, { digest: 'd1' });
    expect(postJson).toHaveBeenNthCalledWith(2, itemOrder.confirm_url);
    expect(result.redirectTo).toBe('/accounts/a/agents/aria/onboarding');
    expect(phases).toEqual(['adding', 'confirming']);
  });

  test('a changed price surfaces the new quote and sends nothing further', async () => {
    const newQuote = { ...quote, added_cents: 1500, digest: 'd2' };
    postJson.mockRejectedValueOnce(
      Object.assign(new Error('The price changed.'), { data: { error: 'The price changed.', item_quote: newQuote } })
    );

    const error = await confirmAddToBill({ payment: itemOrder, pollMs: 0 }).catch((e) => e);

    expect(error.itemQuote).toEqual(newQuote);
    expect(error.payment.item_quote.digest).toBe('d2');
    expect(error.payment.confirm_item_url).toBe(itemOrder.confirm_item_url);
    expect(postJson).toHaveBeenCalledTimes(1);
  });

  test('an uncertain answer keeps the order to retry through its payment url', async () => {
    postJson.mockRejectedValueOnce(
      Object.assign(new Error('Stripe is slow.'), {
        data: { error: 'Stripe is slow.', order: itemOrder.order, payment_url: '/p2', confirm_url: '/c2' },
      })
    );

    const error = await confirmAddToBill({ payment: itemOrder, pollMs: 0 }).catch((e) => e);

    expect(error.payment.payment_url).toBe('/p2');
    expect(error.itemQuote).toBeUndefined();
  });

  test('resuming an order not yet accepted shows the quote again', async () => {
    postJson.mockResolvedValueOnce({ ...itemOrder, item_quote: { ...quote, digest: 'd3' } });

    const result = await payAgain({ billing, payment: itemOrder, pollMs: 0 });

    expect(result.itemQuote.digest).toBe('d3');
    expect(stripe.confirmCardPayment).not.toHaveBeenCalled();
  });

  test('resuming an order already accepted goes straight to confirming', async () => {
    postJson
      .mockResolvedValueOnce({
        order: itemOrder.order,
        accepted: true,
        payment_url: itemOrder.payment_url,
        confirm_url: itemOrder.confirm_url,
      })
      .mockResolvedValueOnce({ order: { state: 'born' }, redirect_to: '/born' });

    const result = await payAgain({ billing, payment: itemOrder, pollMs: 0 });

    expect(postJson).toHaveBeenNthCalledWith(2, itemOrder.confirm_url);
    expect(result.redirectTo).toBe('/born');
    expect(postJson).not.toHaveBeenCalledWith(itemOrder.confirm_item_url, expect.anything());
  });

  test('a failed item order never says a payment went through', async () => {
    postJson
      .mockResolvedValueOnce({ order: itemOrder.order, accepted: true })
      .mockResolvedValueOnce({ order: { state: 'failed', resident_name: 'Aria' } });

    const error = await confirmAddToBill({ payment: itemOrder, pollMs: 0 }).catch((e) => e);

    expect(error.message).toBe(
      "Aria was added to the account's bill but couldn't be created just yet. The house has been told and will put it right; nothing more will be added."
    );
    expect(error.message).not.toMatch(/payment went through/);
    expect(error.payment.confirm_url).toBe(itemOrder.confirm_url);
  });

  test('a stuck item order says it is on the bill, and falls back to "The resident"', async () => {
    const nameless = { ...itemOrder, order: { ...itemOrder.order, resident_name: undefined } };
    postJson.mockResolvedValueOnce({ order: nameless.order, accepted: true }).mockRejectedValue(new Error('offline'));

    const error = await confirmAddToBill({ payment: nameless, pollMs: 0 }).catch((e) => e);

    expect(error.message).toBe(
      "The resident is on the account's bill, but the house could not finish creating it just now. Press the button again to finish: nothing more will be added."
    );
    expect(error.message).not.toMatch(/payment went through/);
  });
});
