// The creation wizard's pay state, and what it does with item orders.
//
// An item order: in an account with a live Stripe subscription, a new paid
// resident is added to that subscription as an item, charged on the next
// bill and nothing today. The house first answers with a quote; the owner
// confirms it, and only then is anything sent to Stripe.
//
// A quote is for the draft as it was when the order was made, so every item
// order the wizard keeps carries quoted_for, that draft's fingerprint. While
// the order is known to be unsent (its quote came this visit and was not
// confirmed), an edit that changes the fingerprint makes the quote stale: the
// wizard forgets the order, and the next Create starts a fresh one (the house
// abandons the unsent one). An order whose fate is unknown (kept in the draft,
// or a confirm that failed) is resumed first; if the house answers with a
// quote for another draft, it is replaced then. An accepted order is never
// replaced: it is always resumed.

export function isItemPayment(payment) {
  return Boolean(payment && (payment.order?.kind === 'item' || payment.item_quote || payment.confirm_item_url));
}

// What the quote was made for: the plan and everything the resident is
// created from. The provider key is left out: it is never kept in the draft.
export function draftFingerprint({ tier, rate, trial, agent, selectedModel, openBeginning }) {
  return JSON.stringify([
    tier ?? null,
    rate ?? 'standard',
    Boolean(trial),
    (agent?.name || '').trim(),
    openBeginning ? '' : (agent?.system_prompt || '').trim(),
    selectedModel ?? null,
    Boolean(openBeginning),
    agent?.colour ?? null,
    agent?.icon ?? null,
  ]);
}

// An item order the owner has not confirmed, quoted for another draft.
export function staleQuote(payment, fingerprint) {
  return Boolean(
    isItemPayment(payment) &&
      !payment.accepted &&
      !payment.paid &&
      payment.quoted_for &&
      payment.quoted_for !== fingerprint
  );
}

export class WizardPay {
  phase = $state(null);
  error = $state(null);
  // The order this draft is paying with, kept so a retry resumes it.
  lastPayment = $state(null);
  // An item order whose quote is on screen, waiting for the owner.
  itemPayment = $state(null);
  // The last order's quote came this visit and has not been sent.
  unsent = $state(false);
  deferred = $derived(isItemPayment(this.lastPayment));
  accepted = $derived(Boolean(this.lastPayment?.accepted));
  settled = $derived(Boolean(this.lastPayment?.paid || this.lastPayment?.accepted));

  constructor(finish) {
    this.finish = finish;
  }

  // Whether Create resumes the kept order rather than starting another. Card
  // orders are replaced by choosing another plan until paid; item orders are
  // always resumed (a known-unsent stale one has been forgotten already).
  resumes(plan, trial) {
    const payment = this.lastPayment;
    if (!payment) return false;
    if (payment.paid || payment.accepted || isItemPayment(payment)) return true;
    return (
      payment.order?.tier === plan?.tier &&
      (payment.order?.rate ?? 'standard') === plan?.rate &&
      Boolean(payment.order?.trial) === trial
    );
  }

  // A quote arrived: nothing is charged until the owner confirms it.
  quoted = (payment, quotedFor) => {
    this.lastPayment = { ...payment, quoted_for: quotedFor };
    this.itemPayment = this.lastPayment;
    this.unsent = true;
    this.phase = null;
  };

  confirmed = (result) => {
    this.itemPayment = null;
    this.unsent = false;
    this.finish(result);
  };

  confirmFailed = (error) => {
    const quotedFor = this.lastPayment?.quoted_for;
    this.phase = null;
    if (error.payment) this.lastPayment = { ...error.payment, quoted_for: quotedFor };
    // A changed price is shown by the panel itself, with the new quote.
    if (error.itemQuote) {
      this.error = null;
      return;
    }
    // It may have reached Stripe: resume it through its payment URL.
    this.unsent = false;
    this.itemPayment = null;
    this.error = error.message;
  };

  // "Not now": the order stays and can be resumed.
  dismiss = () => {
    this.itemPayment = null;
  };

  // An edit changed what was quoted: forget the unsent order.
  invalidate() {
    this.itemPayment = null;
    this.lastPayment = null;
    this.unsent = false;
    this.error = null;
  }

  // Called whenever the draft's fingerprint may have changed.
  check(fingerprint) {
    if (this.unsent && staleQuote(this.lastPayment, fingerprint)) this.invalidate();
  }
}
