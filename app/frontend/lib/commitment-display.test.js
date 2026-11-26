import { describe, expect, it } from 'vitest';
import { commitmentRecurrenceLine, commitmentStatusLine } from './commitment-display';

const recurring = { status: 'scheduled', recurrence: { min_minutes: 60, max_minutes: 90, phrase: 'every 60–90 minutes' }, occurrence: 1 };

describe('commitment recurrence', () => {
  it('says nothing for a one-shot commitment', () => {
    expect(commitmentRecurrenceLine({ status: 'scheduled' })).toBe('');
    expect(commitmentStatusLine({ status: 'scheduled' })).toBe('Scheduled.');
  });

  it('follows the state with how often it recurs', () => {
    expect(commitmentStatusLine(recurring)).toBe('Scheduled. Recurs every 60–90 minutes until cancelled.');
    expect(commitmentRecurrenceLine({ ...recurring, occurrence: 3 })).toBe('Recurs every 60–90 minutes (occurrence 3) until cancelled.');
  });

  it('says when the series has ended, and why when it was not a cancel', () => {
    expect(commitmentRecurrenceLine({ ...recurring, series_ended_reason: 'cancelled' })).toBe('Recurred every 60–90 minutes; the series has ended.');
    expect(commitmentRecurrenceLine({ ...recurring, series_ended_reason: 'next_occurrence_failed' })).toMatch(/could not be scheduled/);
    const capped = { ...recurring, recurrence: { ...recurring.recurrence, max_occurrences: 6 } };
    expect(commitmentRecurrenceLine(capped)).toBe('Recurs every 60–90 minutes, at most 6 times, until cancelled.');
    expect(commitmentRecurrenceLine({ ...capped, series_ended_reason: 'max_occurrences_reached' })).toBe('Recurred every 60–90 minutes; the series has ended after 6 occurrences.');
  });
});
