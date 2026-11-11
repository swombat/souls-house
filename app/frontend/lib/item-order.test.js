import { describe, it, expect, vi } from 'vitest';
import { WizardPay, draftFingerprint, isItemPayment, staleQuote } from './item-order.svelte.js';

const draft = {
  tier: 'conversation',
  rate: 'standard',
  trial: false,
  agent: { name: 'Aria', system_prompt: 'Be curious.', colour: null, icon: null },
  selectedModel: 'house/claude-haiku-5.5',
  openBeginning: false,
};
const itemPayment = {
  order: { id: 'o1', kind: 'item', tier: 'conversation', rate: 'standard' },
  item_quote: { digest: 'd1' },
  confirm_item_url: '/o1/confirm_item',
  payment_url: '/o1/payment',
};

describe('draftFingerprint', () => {
  it('changes with the size, the name, the seed and the model', () => {
    const base = draftFingerprint(draft);
    expect(draftFingerprint({ ...draft, tier: 'business' })).not.toBe(base);
    expect(draftFingerprint({ ...draft, agent: { ...draft.agent, name: 'Bea' } })).not.toBe(base);
    expect(draftFingerprint({ ...draft, agent: { ...draft.agent, system_prompt: 'Be brave.' } })).not.toBe(base);
    expect(draftFingerprint({ ...draft, selectedModel: 'openai/gpt-6-astra' })).not.toBe(base);
    expect(draftFingerprint({ ...draft, openBeginning: true })).not.toBe(base);
    expect(draftFingerprint({ ...draft })).toBe(base);
  });
});

describe('staleQuote', () => {
  const fp = draftFingerprint(draft);
  it('is stale only for an unaccepted item order quoted for another draft', () => {
    expect(staleQuote({ ...itemPayment, quoted_for: 'other' }, fp)).toBe(true);
    expect(staleQuote({ ...itemPayment, quoted_for: fp }, fp)).toBe(false);
    expect(staleQuote({ ...itemPayment, quoted_for: 'other', accepted: true }, fp)).toBe(false);
    expect(staleQuote({ ...itemPayment }, fp)).toBe(false);
    expect(staleQuote({ order: { tier: 'conversation' }, quoted_for: 'other' }, fp)).toBe(false);
  });
});

describe('WizardPay', () => {
  it('forgets an unsent quote when the draft changes, but never an accepted order', () => {
    const pay = new WizardPay(vi.fn());
    pay.quoted(itemPayment, 'a');
    expect(isItemPayment(pay.lastPayment)).toBe(true);
    pay.check('a');
    expect(pay.itemPayment).not.toBeNull();
    pay.check('b');
    expect(pay.itemPayment).toBeNull();
    expect(pay.lastPayment).toBeNull();

    pay.quoted(itemPayment, 'a');
    pay.confirmFailed(Object.assign(new Error('stuck'), { payment: { ...itemPayment, accepted: true } }));
    pay.check('b');
    expect(pay.lastPayment.accepted).toBe(true);
    expect(pay.resumes({ tier: 'business', rate: 'standard' }, false)).toBe(true);
  });

  it('keeps the order and the new quote when the price changed', () => {
    const pay = new WizardPay(vi.fn());
    pay.quoted(itemPayment, 'a');
    const changed = { ...itemPayment, item_quote: { digest: 'd2' } };
    pay.confirmFailed(Object.assign(new Error('changed'), { itemQuote: changed.item_quote, payment: changed }));
    expect(pay.error).toBeNull();
    expect(pay.lastPayment.item_quote.digest).toBe('d2');
    expect(pay.lastPayment.quoted_for).toBe('a');
    expect(pay.unsent).toBe(true);
  });

  it('replaces an unpaid card order on another plan, as before', () => {
    const pay = new WizardPay(vi.fn());
    pay.lastPayment = { order: { tier: 'conversation', rate: 'standard', trial: false }, client_secret: 's' };
    expect(pay.resumes({ tier: 'conversation', rate: 'standard' }, false)).toBe(true);
    expect(pay.resumes({ tier: 'business', rate: 'standard' }, false)).toBe(false);
  });

  it('never forgets an order once its confirm is sent, even before the answer', () => {
    const pay = new WizardPay(vi.fn());
    pay.quoted(itemPayment, 'a');
    // The panel says 'adding' just before the confirm request goes.
    pay.setPhase('adding');
    expect(pay.phase).toBe('adding');
    expect(pay.unsent).toBe(false);
    expect(pay.lastPayment.sent).toBe(true);

    // An edit while the answer is still out keeps the order and its resume URL.
    pay.check('b');
    expect(pay.lastPayment.payment_url).toBe('/o1/payment');
    expect(staleQuote(pay.lastPayment, 'b')).toBe(false);
    expect(pay.resumes({ tier: 'business', rate: 'standard' }, false)).toBe(true);

    // A lost answer keeps it too.
    pay.confirmFailed(Object.assign(new Error('timeout'), { payment: itemPayment }));
    pay.check('c');
    expect(pay.lastPayment.sent).toBe(true);
    expect(pay.lastPayment.order.id).toBe('o1');
  });

  it('a moved price refused before sending is unsent again', () => {
    const pay = new WizardPay(vi.fn());
    pay.quoted(itemPayment, 'a');
    pay.setPhase('adding');
    const changed = { ...itemPayment, item_quote: { digest: 'd2' } };
    pay.confirmFailed(Object.assign(new Error('changed'), { itemQuote: changed.item_quote, payment: changed }));
    expect(pay.unsent).toBe(true);
    expect(pay.lastPayment.sent).toBe(false);
    pay.check('b');
    expect(pay.lastPayment).toBeNull();
  });
});
