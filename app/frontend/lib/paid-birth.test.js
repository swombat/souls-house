import { vi } from 'vitest';

const stripe = { confirmCardPayment: vi.fn() };
const postJson = vi.fn();
vi.mock('$lib/stripe', () => ({ loadStripe: vi.fn(async () => stripe), postJson: (...args) => postJson(...args) }));

const { payForResident, payAgain, trialOrderState } = await import('./paid-birth.js');

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
