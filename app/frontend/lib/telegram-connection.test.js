import { describe, expect, it } from 'vitest';
import { availabilityMessage, formatCountdown, loginErrorMessage, passwordOutcomeMessage } from './telegram-connection';

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
