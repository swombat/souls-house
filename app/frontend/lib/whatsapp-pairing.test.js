import { describe, expect, it } from 'vitest';
import {
  EXPIRY_GRACE_SECONDS,
  PHONE_FIRST_QUERY,
  defaultPairingMethod,
  formatPhoneCode,
  newerQr,
  pairingPhase,
  phoneFailureMessage,
  phonePairingPhase,
  phonePairingUnderway,
} from './whatsapp-pairing';

const at = (seconds) => new Date(Date.UTC(2026, 9, 13, 9, 0, seconds)).toISOString();
const qr = (code, issued, expires) => ({ code, issued_at: at(issued), expires_at: at(expires) });

describe('newerQr', () => {
  it('takes the first code and a newer one', () => {
    const a = qr('A', 0, 60);
    const b = qr('B', 20, 40);
    expect(newerQr(null, a)).toBe(a);
    expect(newerQr(a, b)).toBe(b);
  });

  it('never lets an older code replace a newer one, even if it expires later', () => {
    const b = qr('B', 20, 40);
    expect(newerQr(b, qr('A', 0, 60))).toBe(b);
  });

  it('keeps the last code when the server has none near or past its expiry (it then shows as expired)', () => {
    const b = qr('B', 20, 40);
    expect(newerQr(b, null, Date.parse(at(45)))).toBe(b);
    expect(newerQr(b, null, Date.parse(at(35)))).toBe(b);
    expect(newerQr(null, null)).toBeNull();
  });

  it('drops a code the server cleared while it still had time left', () => {
    expect(newerQr(qr('B', 20, 60), null, Date.parse(at(25)))).toBeNull();
  });
});

describe('pairingPhase', () => {
  const code = qr('A', 0, 60);
  it('names each state the card shows', () => {
    expect(pairingPhase({ status: 'pairing', qr: null })).toBe('waiting');
    expect(pairingPhase({ status: 'pairing', qr: code, secondsLeft: 12 })).toBe('scan');
    expect(pairingPhase({ status: 'pairing', qr: code, secondsLeft: 0, secondsSinceExpiry: 1 })).toBe('rotating');
    expect(
      pairingPhase({ status: 'pairing', qr: code, secondsLeft: 0, secondsSinceExpiry: EXPIRY_GRACE_SECONDS })
    ).toBe('expired');
    expect(pairingPhase({ status: 'connected', qr: code })).toBe('connected');
    expect(pairingPhase({ status: 'reauthorizing' })).toBe('logged_out');
    expect(pairingPhase({ status: 'error' })).toBe('error');
  });
});

describe('phone number pairing', () => {
  it('leads with the phone number on a phone-sized or touch screen, with the QR on a desktop', () => {
    expect(defaultPairingMethod(true)).toBe('phone');
    expect(defaultPairingMethod(false)).toBe('qr');
    expect(PHONE_FIRST_QUERY).toContain('(pointer: coarse)');
    expect(PHONE_FIRST_QUERY).toContain('(max-width: 639px)');
  });

  it('formats the code as XXXX-XXXX however it arrives', () => {
    expect(formatPhoneCode('ABCD2345')).toBe('ABCD-2345');
    expect(formatPhoneCode('abcd-2345')).toBe('ABCD-2345');
    expect(formatPhoneCode(null)).toBe('');
  });

  it('follows the phone pairing from the number to the code to its expiry', () => {
    const code = { code: 'ABCD-2345', expires_at: at(160) };
    expect(phonePairingPhase({ status: 'pairing', phone: {}, phoneCode: null, secondsLeft: 0 })).toBe('number');
    expect(phonePairingPhase({ status: 'pairing', phone: { step: 'requested' }, phoneCode: null })).toBe('requesting');
    expect(phonePairingPhase({ status: 'pairing', phone: { step: 'code' }, phoneCode: code, secondsLeft: 90 })).toBe(
      'code'
    );
    expect(phonePairingPhase({ status: 'pairing', phone: { step: 'code' }, phoneCode: code, secondsLeft: 0 })).toBe(
      'expired'
    );
    expect(phonePairingPhase({ status: 'pairing', phone: { error: 'expired' }, phoneCode: null })).toBe('expired');
    expect(phonePairingPhase({ status: 'pairing', phone: { error: 'rate_limited' }, phoneCode: null })).toBe('failed');
    expect(phonePairingPhase({ status: 'connected', phone: {}, phoneCode: code, secondsLeft: 90 })).toBe('inactive');
  });

  it('keeps a phone pairing under way on screen', () => {
    expect(phonePairingUnderway({}, null)).toBe(false);
    expect(phonePairingUnderway({ step: 'requested' }, null)).toBe(true);
    expect(phonePairingUnderway({}, { code: 'ABCD-2345' })).toBe(true);
    expect(phonePairingUnderway({ error: 'not_ready' }, null)).toBe(true);
  });

  it('explains each failure in words, never the raw reason', () => {
    expect(phoneFailureMessage('phone_invalid')).toMatch(/did not accept that number/);
    expect(phoneFailureMessage('rate_limited')).toMatch(/Wait a few minutes/);
    expect(phoneFailureMessage('anything')).toMatch(/could not make a code/);
    expect(phoneFailureMessage('anything')).not.toContain('anything');
  });
});
