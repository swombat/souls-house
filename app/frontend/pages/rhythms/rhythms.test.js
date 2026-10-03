import { render, screen, waitFor, fireEvent } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import RhythmsIndex from './index.svelte';
import RhythmForm from './form.svelte';
import RhythmShow from './show.svelte';
import RhythmProvenanceBadge from '$lib/components/chat/RhythmProvenanceBadge.svelte';
import RhythmResidentPicker from '$lib/components/rhythms/RhythmResidentPicker.svelte';

const account = { id: 'acc' };
const residents = [
  { id: 'lume', name: 'Lume', colour: 'orange', paused: false },
  { id: 'mira', name: 'Mira', colour: 'teal', paused: false },
];

test('an unavailable existing selection can be removed but not selected again', async () => {
  render(RhythmResidentPicker, {
    residents: [{ id: 'old', name: 'Former resident', unavailable: true }],
    selected: ['old'],
  });
  const button = screen.getByRole('button', { name: /Former resident/ });
  expect(button).not.toBeDisabled();
  await fireEvent.click(button);
  expect(button).toBeDisabled();
});

function rhythmFixture(overrides = {}) {
  return {
    id: 'r1',
    title: 'Weekly reflection',
    opening: 'What did this week do to you?',
    append_date: true,
    resident_ids: ['lume'],
    residents: [residents[0]],
    cadence: 'weekly',
    time_of_day: '09:00',
    weekday: 5,
    month_day: null,
    month: null,
    timezone: 'Madrid',
    timezone_identifier: 'Europe/Madrid',
    next_run_at: '2026-10-09T07:00:00Z',
    schedule_description: 'Every Friday at 09:00',
    creator: { id: 'u1', name: 'Daniel' },
    state: 'active',
    holds: [],
    occurrences: [],
    can_manage: true,
    can_resume: false,
    start_request_key: 'key-1',
    ...overrides,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  globalThis.fetch = vi.fn(() =>
    Promise.resolve({
      ok: true,
      json: () =>
        Promise.resolve({
          next_run_at: '2026-10-05T07:00:00Z',
          preview_title: 'Weekly reflection — 5 Oct 2026',
          schedule_description: 'Every Monday at 09:00',
        }),
    })
  );
});

test('an empty account is asked what it would like to come back to', () => {
  render(RhythmsIndex, { account, rhythms: [] });
  expect(screen.getByText('What would you like to come back to?')).toBeInTheDocument();
});

test('the list shows schedule, residents, creator and the next time in the rhythm timezone', () => {
  render(RhythmsIndex, { account, rhythms: [rhythmFixture()] });
  expect(screen.getByText('Every Friday at 09:00')).toBeInTheDocument();
  expect(screen.getByText('Set up by Daniel')).toBeInTheDocument();
  expect(screen.getByText(/Next: .*09:00/)).toBeInTheDocument();
});

test('a paused rhythm names who is holding it instead of a next time', () => {
  const holds = [{ id: 'h1', holder_name: 'Mira', holder_type: 'agent', reason: 'Not useful lately' }];
  render(RhythmsIndex, { account, rhythms: [rhythmFixture({ state: 'paused', holds })] });
  expect(screen.getByText('Paused by Mira')).toBeInTheDocument();
  expect(screen.queryByText(/Next:/)).not.toBeInTheDocument();
});

test('the form asks the server for the preview and shows the first occurrence', async () => {
  render(RhythmForm, { account, residents, timezones: [{ value: 'Europe/Madrid', label: 'Madrid' }] });
  await waitFor(() => expect(screen.getByText('Weekly reflection — 5 Oct 2026')).toBeInTheDocument());
  const url = globalThis.fetch.mock.calls.at(-1)[0];
  expect(url).toMatch(/^\/accounts\/acc\/rhythms\/preview\?/);
  expect(url).toContain('rhythm%5Bcadence%5D=weekly');
});

test('the form only shows the schedule fields the cadence needs', async () => {
  render(RhythmForm, { account, residents, timezones: [] });
  expect(screen.getByLabelText('On')).toBeInTheDocument();
  expect(screen.queryByLabelText('Day')).not.toBeInTheDocument();

  await fireEvent.change(screen.getByLabelText('How often'), { target: { value: 'monthly' } });
  expect(screen.queryByLabelText('On')).not.toBeInTheDocument();
  expect(screen.getByLabelText('Day')).toBeInTheDocument();

  await fireEvent.change(screen.getByLabelText('Day'), { target: { value: '31' } });
  expect(screen.getByText(/last day of the month/)).toBeInTheDocument();
});

test('the form shows server validation errors next to their fields', () => {
  render(RhythmForm, {
    account,
    residents,
    timezones: [],
    rhythm: rhythmFixture({ id: null, errors: { agents: ['Choose at least one resident'] } }),
  });
  expect(screen.getByText('Choose at least one resident')).toBeInTheDocument();
});

test("a resident's pause is shown with who holds it, and only they can lift it", () => {
  const holds = [{ id: 'h1', holder_name: 'Lume', holder_type: 'agent', reason: 'Nothing new for three weeks' }];
  render(RhythmShow, { account, rhythm: rhythmFixture({ state: 'paused', holds, can_resume: false }) });
  expect(screen.getByText('Nothing new for three weeks')).toBeInTheDocument();
  expect(screen.getByText(/can only be lifted by that resident/)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /Resume/ })).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: /Start one now/ })).toBeDisabled();
});

test('starting one now sends the request key so a double click cannot start two', async () => {
  render(RhythmShow, { account, rhythm: rhythmFixture() });
  await fireEvent.click(screen.getByRole('button', { name: /Start one now/ }));
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/acc/rhythms/r1/start',
    { request_key: 'key-1' },
    expect.any(Object)
  );
});

test('occurrences show late, manual and failure states honestly', () => {
  const occurrences = [
    {
      id: 'o1',
      title: 'Weekly reflection — 2 Oct 2026',
      scheduled_for: '2026-10-02T07:00:00Z',
      late: true,
      manual: false,
      status: 'expired · resident unavailable',
      chat_url: '/accounts/acc/chats/c1',
    },
    {
      id: 'o2',
      title: 'Weekly reflection — 3 Oct 2026',
      scheduled_for: '2026-10-03T16:00:00Z',
      late: false,
      manual: true,
      status: 'accepted · 31: running',
      chat_url: null,
    },
  ];
  render(RhythmShow, { account, rhythm: rhythmFixture({ occurrences }) });
  expect(screen.getByText('late')).toBeInTheDocument();
  expect(screen.getByText('started by hand')).toBeInTheDocument();
  expect(screen.getByText('expired · resident unavailable')).toBeInTheDocument();
});

test('a scheduled message carries its provenance', () => {
  render(RhythmProvenanceBadge, {
    provenance: {
      title: 'Weekly reflection',
      creator_name: 'Daniel',
      scheduled_for: '2026-10-09T07:00:00Z',
      manual: false,
      rhythm_url: '/accounts/acc/rhythms/r1',
    },
  });
  expect(screen.getByText('Scheduled by Daniel')).toBeInTheDocument();
  expect(screen.getByRole('link', { name: 'Rhythm: Weekly reflection' })).toHaveAttribute(
    'href',
    '/accounts/acc/rhythms/r1'
  );
});
