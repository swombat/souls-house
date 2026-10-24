import { describe, expect, it } from 'vitest';
import {
  availabilityMessage,
  codeOutcomeMessage,
  codeSentText,
  formatCountdown,
  loginErrorMessage,
  passwordOutcomeMessage,
  phoneOutcomeMessage,
} from './telegram-connection';

describe('Telegram connection wording', () => {
  it('names each login failure plainly', () => {
    expect(loginErrorMessage({})).toBeNull();
    expect(loginErrorMessage({ error: 'expired' })).toMatch(/^The code expired/);
    expect(loginErrorMessage({ error: 'flood_wait', retry_after: 1 })).toBe('Telegram asked us to wait 1 second.');
    expect(loginErrorMessage({ error: 'cancelled' })).toBe('Sign-in was cancelled.');
    expect(loginErrorMessage({ error: 'failed' })).toMatch(/^Sign-in failed/);
  });

  it('maps password outcomes and errors', () => {
    expect(passwordOutcomeMessage({ outcome: 'accepted' }).tone).toBe('ok');
    expect(passwordOutcomeMessage({ outcome: 'flood_wait', retry_after: 12 }).text).toBe(
      'Telegram asked us to wait 12 seconds.'
    );
    expect(passwordOutcomeMessage({ error: 'Enter the password' }).text).toBe('Enter the password');
  });

  it('says where Telegram sent the code', () => {
    expect(codeSentText({ delivery: 'app' })).toMatch(/^Telegram sent a code to your Telegram app/);
    expect(codeSentText({ delivery: 'sms' })).toBe('Telegram sent a code by SMS.');
    expect(codeSentText({ delivery: 'nonsense' })).toBe('Telegram sent a code.');
  });

  it('maps phone and code outcomes plainly', () => {
    expect(phoneOutcomeMessage({ outcome: 'code_sent' })).toBeNull();
    expect(phoneOutcomeMessage({ outcome: 'phone_invalid' }).text).toMatch(/international format/);
    expect(phoneOutcomeMessage({ outcome: 'unsupported' }).text).toMatch(/QR code/);
    // A resend Telegram cannot deliver: no QR is showing, the earlier code stands.
    expect(phoneOutcomeMessage({ outcome: 'unsupported' }, { resend: true }).text).toMatch(/code already sent/);
    expect(phoneOutcomeMessage({ outcome: 'unsupported' }, { resend: true }).text).not.toMatch(/QR/);
    expect(phoneOutcomeMessage({ outcome: 'expired' }).text).toMatch(/^This sign-in expired\. Restart/);
    expect(phoneOutcomeMessage({ outcome: 'flood_wait', retry_after: 5 }).text).toBe(
      'Telegram asked us to wait 5 seconds.'
    );
    expect(phoneOutcomeMessage({ error: 'This sign-in has moved on.' }).text).toBe('This sign-in has moved on.');
    expect(codeOutcomeMessage({ outcome: 'accepted' }).tone).toBe('ok');
    expect(codeOutcomeMessage({ outcome: 'code_invalid' }).tone).toBe('error');
    expect(codeOutcomeMessage({ outcome: 'code_expired' }).text).toBe('That code expired. Send a new one.');
    expect(codeOutcomeMessage({ outcome: 'phone_unregistered' }).text).toMatch(/no Telegram account/);
    expect(codeOutcomeMessage({ outcome: 'not_configured' }).text).toMatch(/not set up/);
  });

  it('says nothing when the connector is fine', () => {
    expect(availabilityMessage({ state: 'ok' })).toBeNull();
    for (const state of ['queued', 'busy', 'backlogged', 'unavailable'])
      expect(availabilityMessage({ state })).toBeTruthy();
  });

  it('formats the countdown', () => {
    expect(formatCountdown(65)).toBe('1:05');
  });

  it('never uses an exclamation mark', () => {
    const texts = [
      ...['expired', 'password_invalid', 'flood_wait', 'failed', 'cancelled'].map((error) =>
        loginErrorMessage({ error })
      ),
      ...['accepted', 'password_invalid', 'flood_wait', 'failed', 'not_configured'].map(
        (outcome) => passwordOutcomeMessage({ outcome }).text
      ),
      ...['queued', 'busy', 'backlogged', 'unavailable'].map((state) => availabilityMessage({ state })),
    ];
    for (const text of texts) expect(text).not.toContain('!');
  });
});
