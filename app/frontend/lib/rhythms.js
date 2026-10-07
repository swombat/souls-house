// Small helpers for the Rhythms screens. Schedules are computed in Rails;
// nothing here does calendar arithmetic, it only formats what the server sent.

export const CADENCES = [
  { value: 'daily', label: 'Every day' },
  { value: 'weekly', label: 'Every week' },
  { value: 'monthly', label: 'Every month' },
  { value: 'yearly', label: 'Every year' },
];

// Ruby's Date#wday convention: 0 = Sunday.
export const WEEKDAYS = [
  { value: 1, label: 'Monday' },
  { value: 2, label: 'Tuesday' },
  { value: 3, label: 'Wednesday' },
  { value: 4, label: 'Thursday' },
  { value: 5, label: 'Friday' },
  { value: 6, label: 'Saturday' },
  { value: 0, label: 'Sunday' },
];

export const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
].map((label, index) => ({ value: index + 1, label }));

export const MONTH_DAYS = Array.from({ length: 31 }, (_, index) => index + 1);

export const rhythmsPath = (accountId) => `/accounts/${accountId}/rhythms`;
export const newRhythmPath = (accountId) => `${rhythmsPath(accountId)}/new`;
export const rhythmPath = (accountId, id) => `${rhythmsPath(accountId)}/${id}`;
export const editRhythmPath = (accountId, id) => `${rhythmPath(accountId, id)}/edit`;
export const rhythmPreviewPath = (accountId) => `${rhythmsPath(accountId)}/preview`;
export const rhythmActionPath = (accountId, id, action) => `${rhythmPath(accountId, id)}/${action}`;

export const FORM_FIELDS = [
  'title',
  'opening',
  'append_date',
  'resident_ids',
  'cadence',
  'time_of_day',
  'weekday',
  'month_day',
  'month',
  'timezone',
];

export function formValues(rhythm = {}, fallbackTimezone = 'UTC') {
  return {
    title: rhythm.title ?? '',
    opening: rhythm.opening ?? '',
    append_date: rhythm.append_date ?? true,
    resident_ids: [...(rhythm.resident_ids ?? [])],
    cadence: rhythm.cadence ?? 'weekly',
    time_of_day: rhythm.time_of_day ?? '09:00',
    weekday: rhythm.weekday ?? 1,
    month_day: rhythm.month_day ?? 1,
    month: rhythm.month ?? 1,
    timezone: rhythm.timezone ?? fallbackTimezone,
  };
}

// Fields that do not apply to the chosen cadence are sent blank, so the
// server never stores a stale weekday on a daily rhythm.
export function submittableValues(values) {
  const out = { ...values, resident_ids: [...values.resident_ids] };
  if (out.cadence !== 'weekly') out.weekday = null;
  if (out.cadence !== 'monthly' && out.cadence !== 'yearly') out.month_day = null;
  if (out.cadence !== 'yearly') out.month = null;
  return out;
}

export function previewQuery(values) {
  const params = new URLSearchParams();
  const submittable = submittableValues(values);
  for (const field of FORM_FIELDS.filter((field) => !['opening', 'resident_ids'].includes(field))) {
    const value = submittable[field];
    if (value !== null && value !== undefined) {
      params.append(`rhythm[${field}]`, String(value));
    }
  }
  return params.toString();
}

export function fieldErrors(errors, field) {
  if (!errors) return [];
  const value = errors[field] ?? errors[`rhythm.${field}`];
  if (!value) return [];
  return Array.isArray(value) ? value : [value];
}

export function formatWhen(iso, timezone, { withYear = true } = {}) {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  try {
    return new Intl.DateTimeFormat('en-GB', {
      timeZone: timezone || undefined,
      weekday: 'short',
      day: 'numeric',
      month: 'short',
      ...(withYear ? { year: 'numeric' } : {}),
      hour: '2-digit',
      minute: '2-digit',
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

// Rails stores zone names like "Madrid"; Intl needs the IANA identifier.
export function zoneIdentifier(timezone, timezones = []) {
  return timezones.find((zone) => zone.value === timezone)?.identifier ?? timezone;
}

export function needsShortMonthNote(values) {
  if (values.cadence === 'monthly') return Number(values.month_day) > 28;
  if (values.cadence === 'yearly') {
    const shortestMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][Number(values.month) - 1];
    return Number(values.month_day) > shortestMonth;
  }
  return false;
}
