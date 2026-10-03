import { describe, expect, it } from 'vitest';
import {
  fieldErrors,
  formValues,
  formatWhen,
  needsShortMonthNote,
  previewQuery,
  rhythmActionPath,
  zoneIdentifier,
  submittableValues,
} from './rhythms.js';

describe('rhythms helpers', () => {
  it('defaults a new rhythm to a weekly morning with the date appended', () => {
    const values = formValues({}, 'Europe/Madrid');
    expect(values).toMatchObject({ cadence: 'weekly', append_date: true, timezone: 'Europe/Madrid', resident_ids: [] });
  });

  it('blanks schedule fields that do not apply to the cadence', () => {
    const daily = submittableValues({ ...formValues({}), cadence: 'daily' });
    expect(daily).toMatchObject({ weekday: null, month_day: null, month: null });

    const monthly = submittableValues({ ...formValues({}), cadence: 'monthly', month_day: 31 });
    expect(monthly).toMatchObject({ weekday: null, month_day: 31, month: null });
  });

  it('builds nested preview params Rails can read', () => {
    const query = previewQuery({ ...formValues({ resident_ids: ['AYa', 'BJZ'] }), cadence: 'daily' });
    const params = new URLSearchParams(query);
    expect(params.has('rhythm[resident_ids][]')).toBe(false);
    expect(params.has('rhythm[opening]')).toBe(false);
    expect(params.get('rhythm[cadence]')).toBe('daily');
    expect(params.has('rhythm[weekday]')).toBe(false);
  });

  it('reads errors keyed either way and always returns a list', () => {
    expect(fieldErrors({ title: "can't be blank" }, 'title')).toEqual(["can't be blank"]);
    expect(fieldErrors({ 'rhythm.opening': ['too short'] }, 'opening')).toEqual(['too short']);
    expect(fieldErrors(null, 'title')).toEqual([]);
  });

  it('formats times in the rhythm timezone, not the browser one', () => {
    expect(formatWhen('2026-10-05T07:00:00Z', 'Europe/Madrid')).toContain('09:00');
    expect(formatWhen('2026-10-05T07:00:00Z', 'Asia/Tokyo')).toContain('16:00');
    expect(formatWhen(null, 'UTC')).toBeNull();
  });

  it('explains short months only when they can matter', () => {
    expect(needsShortMonthNote({ cadence: 'monthly', month_day: 31 })).toBe(true);
    expect(needsShortMonthNote({ cadence: 'monthly', month_day: 28 })).toBe(false);
    expect(needsShortMonthNote({ cadence: 'yearly', month: 2, month_day: 29 })).toBe(true);
    expect(needsShortMonthNote({ cadence: 'yearly', month: 4, month_day: 31 })).toBe(true);
    expect(needsShortMonthNote({ cadence: 'yearly', month: 2, month_day: 30 })).toBe(true);
    expect(needsShortMonthNote({ cadence: 'weekly', month_day: 31 })).toBe(false);
  });

  it('builds member action paths', () => {
    expect(rhythmActionPath('A1', 'R1', 'pause')).toBe('/accounts/A1/rhythms/R1/pause');
  });

  it('maps Rails zone names to IANA identifiers for display', () => {
    const zones = [{ value: 'Madrid', label: '(GMT+01:00) Madrid', identifier: 'Europe/Madrid' }];
    expect(zoneIdentifier('Madrid', zones)).toBe('Europe/Madrid');
    expect(formatWhen('2026-10-05T07:00:00Z', zoneIdentifier('Madrid', zones))).toContain('09:00');
    expect(zoneIdentifier('Europe/Madrid', [])).toBe('Europe/Madrid');
  });
});
