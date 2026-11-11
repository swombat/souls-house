import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
import { useForm, router } from '@inertiajs/svelte';
import { payForResident, payAgain, confirmAddToBill, openCheckout, trialOrderState } from '$lib/paid-birth';
import NewResident from './new.svelte';

vi.mock('$lib/paid-birth', () => ({
  payForResident: vi.fn(),
  payAgain: vi.fn(),
  confirmAddToBill: vi.fn(),
  openCheckout: vi.fn(),
  trialOrderState: vi.fn(async () => 'open'),
}));

const houseModel = 'house/claude-haiku-5.5';
const draftKey = 'helixkit:agent-birth-draft:account';
const props = {
  account: { id: 'account' },
  default_model_id: houseModel,
  grouped_models: {
    'Top Models': [{ model_id: 'openai/gpt-6-astra', label: 'GPT-6 Astra' }],
    'On the house': [
      { model_id: houseModel, label: 'Claude Haiku 5.5 · On the house' },
      { model_id: 'house/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash · On the house' },
    ],
  },
};

beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
});
afterEach(() => localStorage.clear());

test('import options wait behind one link below the form', async () => {
  render(NewResident, {
    ...props,
    github_resident_import_url: '/github-import/new',
    resident_import_url: '/import',
  });
  expect(screen.queryByRole('link', { name: 'Bring an existing GitHub resident' })).not.toBeInTheDocument();

  await fireEvent.click(screen.getByRole('button', { name: 'Import a resident instead' }));

  expect(screen.getByRole('link', { name: 'Bring an existing GitHub resident' })).toHaveAttribute(
    'href',
    '/github-import/new'
  );
  expect(screen.getByRole('link', { name: 'Import a resident archive' })).toHaveAttribute('href', '/import');
});

test('there is no import link without a server-provided URL', () => {
  render(NewResident, props);
  expect(screen.queryByRole('button', { name: 'Import a resident instead' })).not.toBeInTheDocument();
});

test('a fresh resident defaults to the house offering, not the first grouped model', async () => {
  render(NewResident, props);

  expect(useForm.mock.calls[0][0].agent.model_id).toBe(houseModel);
  await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).model_id).toBe(houseModel));
});

test('a saved draft keeps its chosen personal model', async () => {
  localStorage.setItem(draftKey, JSON.stringify({ model_id: 'openai/gpt-6-astra' }));
  render(NewResident, props);

  await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).model_id).toBe('openai/gpt-6-astra'));
});

test('a draft without a model uses the house default', async () => {
  localStorage.setItem(draftKey, JSON.stringify({ name: 'Uncommitted resident' }));
  render(NewResident, props);

  await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).model_id).toBe(houseModel));
  expect(JSON.parse(localStorage.getItem(draftKey)).name).toBe('Uncommitted resident');
});

test('an account that pays per resident gets a sixth step, Plan, and a draft reopens no later than Review', async () => {
  // jsdom has no Web Animations; the step change runs Svelte transitions.
  Element.prototype.animate ||= function () {
    const animation = { cancel() {}, finished: Promise.resolve(), onfinish: null };
    setTimeout(() => animation.onfinish?.());
    return animation;
  };
  localStorage.setItem(
    draftKey,
    JSON.stringify({ name: 'Aria', system_prompt: 'Be curious.', key_path: 'house', step: 5 })
  );
  render(NewResident, {
    ...props,
    billing: { can_pay: true, tiers: [], payment_method: null, contact_email: 'hello@example.com' },
  });

  expect(screen.getByText('Six small steps, a few minutes.', { exact: false })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Go to step 6: Plan' })).toBeInTheDocument();
  await waitFor(() =>
    expect(screen.getByRole('button', { name: 'Go to step 5: Review' })).toHaveAttribute('aria-current', 'step')
  );
});

describe('the Plan step button', () => {
  const small = {
    id: 'conversation',
    tier: 'conversation',
    size: 'small',
    rate: 'standard',
    name: 'Small',
    monthly_usd: '9.99',
    allowance_usd: '10.00',
    purchasable: true,
  };
  const billing = { can_pay: true, offers: [small], payment_method: null, contact_email: 'hello@example.com' };

  async function reachPlanStep(extra, draft = {}) {
    Element.prototype.animate ||= function () {
      const animation = { cancel() {}, finished: Promise.resolve(), onfinish: null };
      setTimeout(() => animation.onfinish?.());
      return animation;
    };
    localStorage.setItem(
      draftKey,
      JSON.stringify({ name: 'Aria', system_prompt: 'Be curious.', key_path: 'house', step: 4, ...draft })
    );
    render(NewResident, { ...props, ...extra });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Go to step 5: Review' })).toHaveAttribute('aria-current', 'step')
    );
    await fireEvent.click(screen.getByRole('checkbox'));
    await fireEvent.click(screen.getByRole('button', { name: /Continue/ }));
  }

  test('says Start free, and needs no card, when the free 14 days apply', async () => {
    await reachPlanStep({ billing, trial: { eligible: true, days: 14 } });
    const button = await screen.findByRole('button', { name: 'Start free' });
    expect(button).toBeEnabled();
  });

  test('without trial props it asks for a card and states the price', async () => {
    await reachPlanStep({ billing });
    const button = await screen.findByRole('button', { name: 'Create Aria · $9.99 a month + VAT' });
    expect(button).toBeDisabled();
  });

  const checkoutUrl = 'https://checkout.stripe.com/c/pay/cs_test_1';
  const trialPayment = {
    order: { id: 'o1', tier: 'conversation', rate: 'standard', trial: true, state: 'pending', resident_name: 'Aria' },
    client_secret: null,
    payment_url: '/accounts/account/birth_orders/o1/payment',
    confirm_url: '/accounts/account/birth_orders/o1/confirm',
    checkout_url: checkoutUrl,
  };

  test('Start free asks for the trial and sends the browser to Stripe Checkout, with no card form', async () => {
    payForResident.mockResolvedValue({ checkoutUrl, payment: trialPayment });
    await reachPlanStep({ billing, trial: { eligible: true, days: 14 } });

    await fireEvent.click(await screen.findByRole('button', { name: 'Start free' }));

    await waitFor(() => expect(openCheckout).toHaveBeenCalledWith(checkoutUrl));
    expect(payForResident).toHaveBeenCalledWith(
      expect.objectContaining({ tier: 'conversation', rate: 'standard', trial: true })
    );
    expect(screen.queryByTestId('plan-card-form')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Add a card' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Opening Stripe…' })).toBeDisabled();
    expect(router.visit).not.toHaveBeenCalled();
    // The draft waits until Stripe has started the trial.
    await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).trial_payment).toEqual(trialPayment));
  });

  test('an account without the trial takes the paid path, unchanged', async () => {
    payForResident.mockResolvedValue({ redirectTo: '/accounts/account/agents/aria/onboarding' });
    const card = { brand: 'visa', last4: '4242', exp_month: 10, exp_year: 2030 };
    await reachPlanStep({ billing: { ...billing, payment_method: card }, trial: { eligible: false, days: 14 } });

    await fireEvent.click(await screen.findByRole('button', { name: 'Create Aria · $9.99 a month + VAT' }));

    await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/accounts/account/agents/aria/onboarding'));
    expect(payForResident).toHaveBeenCalledWith(expect.objectContaining({ tier: 'conversation', trial: false }));
    expect(openCheckout).not.toHaveBeenCalled();
    expect(screen.queryByText(/free/i)).toBeNull();
  });

  test('a refused trial shows the refusal in the step', async () => {
    const refusal = 'This account has already had its free trial. Choose a plan to create the resident.';
    payForResident.mockRejectedValue(Object.assign(new Error(refusal), { data: { error: refusal } }));
    await reachPlanStep({ billing, trial: { eligible: true, days: 14 } });

    await fireEvent.click(await screen.findByRole('button', { name: 'Start free' }));

    const alert = await screen.findByTestId('plan-pay-error');
    expect(alert).toHaveTextContent("The free trial didn't start");
    expect(alert).toHaveTextContent(refusal);
    expect(openCheckout).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Start free' })).toBeEnabled();
  });

  test('a draft back from an open trial Checkout resumes the same order, to the same page', async () => {
    trialOrderState.mockResolvedValue('open');
    payAgain.mockResolvedValue({ checkoutUrl, payment: trialPayment });
    await reachPlanStep({ billing, trial: { eligible: true, days: 14 } }, { trial_payment: trialPayment });

    await fireEvent.click(await screen.findByRole('button', { name: 'Start free' }));

    await waitFor(() => expect(openCheckout).toHaveBeenCalledWith(checkoutUrl));
    expect(trialOrderState).toHaveBeenCalledWith(trialPayment);
    expect(payAgain).toHaveBeenCalledWith(expect.objectContaining({ payment: trialPayment }));
    expect(payForResident).not.toHaveBeenCalled();
  });

  test('a draft whose trial Stripe has started is cleared, not offered again', async () => {
    trialOrderState.mockResolvedValue('done');
    localStorage.setItem(
      draftKey,
      JSON.stringify({ name: 'Aria', system_prompt: 'Be curious.', step: 4, trial_payment: trialPayment })
    );
    render(NewResident, { ...props, billing, trial: { eligible: false, days: 14 } });

    await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).name).toBe(''));
    expect(screen.getByRole('button', { name: 'Go to step 1: Welcome' })).toHaveAttribute('aria-current', 'step');
  });
  describe('an account with a live subscription (item order)', () => {
    const card = { brand: 'visa', last4: '4242', exp_month: 10, exp_year: 2030 };
    const quote = {
      added_cents: 1200,
      next_total_cents: 3400,
      recurring_cents: 2200,
      currency: 'usd',
      next_at: '2026-12-01',
      digest: 'd1',
    };
    const itemPayment = {
      order: {
        id: 'o3',
        kind: 'item',
        tier: 'conversation',
        rate: 'standard',
        state: 'pending',
        resident_name: 'Aria',
      },
      item_quote: quote,
      confirm_item_url: '/accounts/account/birth_orders/o3/confirm_item',
      payment_url: '/accounts/account/birth_orders/o3/payment',
      confirm_url: '/accounts/account/birth_orders/o3/confirm',
    };
    const createName = 'Create Aria · $9.99 a month + VAT';
    const confirmName = "Create Aria and add to the account's bill";

    async function reachQuote() {
      payForResident.mockResolvedValue({ itemQuote: quote, payment: itemPayment });
      await reachPlanStep({ billing: { ...billing, payment_method: card }, trial: { eligible: false, days: 14 } });
      await fireEvent.click(await screen.findByRole('button', { name: createName }));
      await screen.findByTestId('birth-add-confirm');
    }

    test('a quote shows the panel and charges and creates nothing yet', async () => {
      await reachQuote();

      expect(screen.getByTestId('birth-add-confirm')).toHaveTextContent('Nothing is charged today.');
      expect(router.visit).not.toHaveBeenCalled();
      expect(openCheckout).not.toHaveBeenCalled();
      expect(confirmAddToBill).not.toHaveBeenCalled();
      expect(screen.getByRole('button', { name: createName })).toBeDisabled();
    });

    test('confirming adds the resident and goes the way a card order does, and the draft is dropped', async () => {
      confirmAddToBill.mockResolvedValue({ redirectTo: '/accounts/account/agents/aria/onboarding' });
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: confirmName }));

      await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/accounts/account/agents/aria/onboarding'));
      expect(confirmAddToBill).toHaveBeenCalledWith(
        expect.objectContaining({ payment: expect.objectContaining(itemPayment) })
      );
    });

    test('still being confirmed says it is on the bill, never "Payment received"', async () => {
      confirmAddToBill.mockResolvedValue({ redirectTo: null, order: itemPayment.order });
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: confirmName }));

      const pending = await screen.findByTestId('paid-pending');
      expect(pending).toHaveTextContent(
        "Aria is on the account's bill and is being created; it will appear with your residents in a moment."
      );
      expect(pending).not.toHaveTextContent(/Payment received|Stripe is still confirming/);
    });

    test('Not now closes the panel and keeps the order, so the button resumes it with payAgain', async () => {
      payAgain.mockResolvedValue({ itemQuote: quote, payment: itemPayment });
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: 'Not now' }));

      expect(screen.queryByTestId('birth-add-confirm')).toBeNull();
      await fireEvent.click(await screen.findByRole('button', { name: createName }));
      await screen.findByTestId('birth-add-confirm');
      expect(payAgain).toHaveBeenCalledWith(expect.objectContaining({ payment: expect.objectContaining(itemPayment) }));
      expect(payForResident).toHaveBeenCalledTimes(1);
    });

    test('an accepted order that could not be finished resumes the same order, with no card wording', async () => {
      const accepted = { ...itemPayment, accepted: true };
      const stuck = Object.assign(
        new Error("Aria is on the account's bill, but the house could not finish creating it just now."),
        { payment: accepted }
      );
      confirmAddToBill.mockRejectedValue(stuck);
      payAgain.mockResolvedValue({ redirectTo: '/born' });
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: confirmName }));

      const alert = await screen.findByTestId('plan-pay-error');
      expect(alert).toHaveTextContent('Still being created');
      expect(alert).not.toHaveTextContent(/Not added yet|payment didn't go through|different card/);
      await fireEvent.click(await screen.findByRole('button', { name: createName }));

      await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/born'));
      expect(payAgain).toHaveBeenCalledWith(expect.objectContaining({ payment: expect.objectContaining(accepted) }));
      expect(payForResident).toHaveBeenCalledTimes(1);
    });

    test('a failure before the owner accepted says Not added yet', async () => {
      confirmAddToBill.mockRejectedValue(
        Object.assign(new Error('Stripe could not be reached.'), { payment: itemPayment })
      );
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: confirmName }));

      const alert = await screen.findByTestId('plan-pay-error');
      expect(alert).toHaveTextContent('Not added yet');
      expect(alert).not.toHaveTextContent(/Still being created|payment didn't go through/);
    });

    test('the card terms are not shown with the quote', async () => {
      await reachPlanStep({ billing: { ...billing, payment_method: card }, trial: { eligible: false, days: 14 } });
      expect(screen.getByTestId('plan-terms')).toHaveTextContent('Today:');
      payForResident.mockResolvedValue({ itemQuote: quote, payment: itemPayment });

      await fireEvent.click(await screen.findByRole('button', { name: createName }));
      await screen.findByTestId('birth-add-confirm');

      expect(screen.queryByTestId('plan-terms')).toBeNull();
      expect(screen.queryByText(/first month/)).toBeNull();
    });

    test('choosing Large after a Small quote forgets it: the next Create starts a fresh order', async () => {
      const large = { ...small, id: 'business', tier: 'business', size: 'large', name: 'Large', monthly_usd: '49.99' };
      const largePayment = {
        ...itemPayment,
        order: { ...itemPayment.order, id: 'o4', tier: 'business' },
        item_quote: { ...quote, digest: 'd4' },
        confirm_item_url: '/accounts/account/birth_orders/o4/confirm_item',
      };
      payForResident
        .mockResolvedValueOnce({ itemQuote: quote, payment: itemPayment })
        .mockResolvedValueOnce({ itemQuote: largePayment.item_quote, payment: largePayment });
      confirmAddToBill.mockResolvedValue({ redirectTo: '/born' });
      await reachPlanStep({
        billing: { ...billing, offers: [small, large], payment_method: card },
        trial: { eligible: false, days: 14 },
      });
      await fireEvent.click(await screen.findByRole('button', { name: createName }));
      await screen.findByTestId('birth-add-confirm');

      await fireEvent.click(screen.getByRole('radio', { name: 'Large' }));

      await waitFor(() => expect(screen.queryByTestId('birth-add-confirm')).toBeNull());
      await fireEvent.click(await screen.findByRole('button', { name: 'Create Aria · $49.99 a month + VAT' }));
      await screen.findByTestId('birth-add-confirm');
      expect(payAgain).not.toHaveBeenCalled();
      expect(payForResident).toHaveBeenLastCalledWith(expect.objectContaining({ tier: 'business' }));

      await fireEvent.click(screen.getByRole('button', { name: confirmName }));
      await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/born'));
      expect(confirmAddToBill).toHaveBeenCalledTimes(1);
      expect(confirmAddToBill).toHaveBeenCalledWith(
        expect.objectContaining({
          payment: expect.objectContaining({ confirm_item_url: largePayment.confirm_item_url }),
        })
      );
    });

    test('editing the seed after a quote forgets it: the next Create starts a fresh order', async () => {
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: 'Go to step 3: Soul seed' }));
      await fireEvent.input(await screen.findByRole('textbox'), { target: { value: 'Be brave.' } });
      await fireEvent.click(screen.getByRole('button', { name: /Continue/ }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: 'Go to step 4: Runtime' })).toHaveAttribute('aria-current', 'step')
      );
      await fireEvent.click(screen.getByRole('button', { name: /Continue/ }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: 'Go to step 5: Review' })).toHaveAttribute('aria-current', 'step')
      );
      const checkbox = screen.getByRole('checkbox');
      if (!checkbox.checked) await fireEvent.click(checkbox);
      await fireEvent.click(screen.getByRole('button', { name: /Continue/ }));

      expect(screen.queryByTestId('birth-add-confirm')).toBeNull();
      await fireEvent.click(await screen.findByRole('button', { name: createName }));
      await screen.findByTestId('birth-add-confirm');
      expect(payAgain).not.toHaveBeenCalled();
      expect(payForResident).toHaveBeenCalledTimes(2);
      expect(payForResident).toHaveBeenLastCalledWith(
        expect.objectContaining({ agent: expect.objectContaining({ system_prompt: 'Be brave.' }) })
      );
      expect(confirmAddToBill).not.toHaveBeenCalled();
    });

    test('an edit while the confirm is still out keeps the order: the draft holds it through a lost answer', async () => {
      let loseAnswer;
      confirmAddToBill.mockImplementation(({ payment, onPhase }) => {
        onPhase('adding');
        return new Promise((_resolve, reject) => {
          loseAnswer = () => reject(Object.assign(new Error('Stripe could not be reached.'), { payment }));
        });
      });
      payAgain.mockResolvedValue({ redirectTo: '/born' });
      await reachQuote();

      await fireEvent.click(screen.getByRole('button', { name: confirmName }));
      await waitFor(() => expect(loseAnswer).toBeDefined());
      await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).item_payment.sent).toBe(true));

      // The seed is edited while the answer is still out.
      await fireEvent.click(screen.getByRole('button', { name: 'Go to step 3: Soul seed' }));
      await fireEvent.input(await screen.findByRole('textbox'), { target: { value: 'Be brave.' } });
      const kept = JSON.parse(localStorage.getItem(draftKey));
      expect(kept.system_prompt).toBe('Be brave.');
      expect(kept.item_payment.order.id).toBe('o3');
      expect(kept.item_payment.payment_url).toBe(itemPayment.payment_url);

      loseAnswer();
      await waitFor(() => expect(JSON.parse(localStorage.getItem(draftKey)).item_payment.order.id).toBe('o3'));
      expect(payForResident).toHaveBeenCalledTimes(1);
    });

    test('a sent order kept in the draft is resumed after a reload, never replaced', async () => {
      payAgain.mockResolvedValue({ redirectTo: '/born' });
      await reachPlanStep(
        { billing: { ...billing, payment_method: card }, trial: { eligible: false, days: 14 } },
        { item_payment: { ...itemPayment, sent: true, quoted_for: 'another draft' } }
      );

      await fireEvent.click(await screen.findByRole('button', { name: createName }));

      await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/born'));
      expect(payAgain).toHaveBeenCalledWith(
        expect.objectContaining({ payment: expect.objectContaining({ sent: true }) })
      );
      expect(payForResident).not.toHaveBeenCalled();
    });

    test('a kept order still unsent but quoted for another draft is replaced after a reload', async () => {
      payAgain.mockResolvedValue({ itemQuote: quote, payment: itemPayment });
      await reachPlanStep(
        { billing: { ...billing, payment_method: card }, trial: { eligible: false, days: 14 } },
        { item_payment: { ...itemPayment, quoted_for: 'another draft' } }
      );
      payForResident.mockResolvedValue({
        itemQuote: quote,
        payment: { ...itemPayment, order: { ...itemPayment.order, id: 'o5' } },
      });

      await fireEvent.click(await screen.findByRole('button', { name: createName }));

      await screen.findByTestId('birth-add-confirm');
      expect(payAgain).toHaveBeenCalledTimes(1);
      expect(payForResident).toHaveBeenCalledTimes(1);
    });

    test('an item order kept with the draft is resumed after a reload', async () => {
      payAgain.mockResolvedValue({ redirectTo: '/born' });
      await reachPlanStep(
        { billing: { ...billing, payment_method: card }, trial: { eligible: false, days: 14 } },
        { item_payment: { ...itemPayment, accepted: true } }
      );

      await fireEvent.click(await screen.findByRole('button', { name: createName }));

      await waitFor(() => expect(router.visit).toHaveBeenCalledWith('/born'));
      expect(payForResident).not.toHaveBeenCalled();
    });
  });
});
