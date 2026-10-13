import { describe, expect, it } from 'vitest';
import { EXPIRY_GRACE_SECONDS, newerQr, pairingPhase } from './whatsapp-pairing';

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
