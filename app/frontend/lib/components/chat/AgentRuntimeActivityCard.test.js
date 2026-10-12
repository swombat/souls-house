import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import AgentRuntimeActivityCard from './AgentRuntimeActivityCard.svelte';

const base = {
  id: 'a',
  run_id: 'run',
  agent_name: 'Resident',
  active: true,
  status: 'running',
  status_label: 'is working',
  created_at: '2026-09-06T10:00:00Z',
  server_time: '2026-09-06T10:00:00Z',
  reporter_health: 'live',
  last_report_at: '2026-09-06T10:00:00Z',
  events: [],
};

const withCommands = {
  ...base,
  narration_shared: true,
  snapshot: {
    narration_capability: 'supported',
    commentary: 'Checking the configuration.',
    operations: { command: { label: 'cat config/settings.yml' } },
  },
  events: [
    { id: '1', type: 'commentary.completed', data: { text: 'First I checked the tests.' } },
    { id: '2', type: 'tool.finished', data: { label: 'git status', outcome: 'completed' } },
    { id: '3', type: 'warning', data: {} },
  ],
};

test('one compact silence line ages without polling, resets on replies, and disappears at completion', async () => {
  vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval', 'performance', 'Date'] });
  vi.setSystemTime(new Date('2030-01-01T00:00:00Z')); // Deliberately unlike the server clock.
  try {
    const interaction = {
      ...base,
      narration_shared: false,
      started_at: '2026-10-12T10:00:00Z',
      server_time: '2026-10-12T10:01:59Z',
      last_resident_post_at: null,
      reporter_health: 'live',
      last_report_at: '2026-10-12T10:01:59Z',
    };
    const { container, rerender, unmount } = render(AgentRuntimeActivityCard, { interaction });
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    await vi.advanceTimersByTimeAsync(1000);
    await tick();
    expect(screen.getAllByRole('status')).toHaveLength(1);
    expect(screen.getByRole('status')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent('No update from Resident for 2 min · runtime active');
    expect(container.querySelector('details').open).toBe(false);
    await vi.advanceTimersByTimeAsync(30000);
    await tick();
    expect(screen.getByRole('status')).toHaveTextContent('runtime contact uncertain');
    expect(screen.queryByText(/Live updates interrupted/)).not.toBeInTheDocument();
    await rerender({ interaction: { ...interaction, revision: 2 } });
    expect(screen.getByRole('status')).toHaveTextContent('runtime contact uncertain');
    await vi.advanceTimersByTimeAsync(60000);
    await tick();
    expect(screen.getByRole('status')).toHaveTextContent('No update from Resident for 3 min');
    const replied = {
      ...interaction,
      server_time: '2026-10-12T10:03:30Z',
      last_resident_post_at: '2026-10-12T10:03:30Z',
      last_report_at: '2026-10-12T10:03:30Z',
    };
    await rerender({ interaction: replied });
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    await vi.advanceTimersByTimeAsync(120000);
    await tick();
    expect(screen.getByRole('status')).toHaveTextContent('No update from Resident for 2 min');
    await rerender({ interaction: { ...replied, active: false, status: 'completed' } });
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  } finally {
    vi.useRealTimers();
  }
});

test('legacy invocations retain duration and contact behavior without a silence indicator', async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-10-12T10:03:00Z'));
  try {
    const interaction = {
      ...base,
      run_id: null,
      server_time: undefined,
      started_at: '2026-10-12T10:00:00Z',
      reporter_health: 'connecting',
      last_report_at: null,
    };
    const { rerender, unmount } = render(AgentRuntimeActivityCard, { interaction });
    expect(screen.getByText(/180s/)).toBeInTheDocument();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    expect(screen.queryByText(/Live updates interrupted/)).not.toBeInTheDocument();
    await rerender({ interaction: { ...interaction, last_report_at: '2026-10-12T10:02:00Z' } });
    expect(screen.getByText(/Live updates interrupted/)).toBeInTheDocument();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    unmount();
  } finally {
    vi.useRealTimers();
  }
});

test('narration stays visible while live commands and command history are expandable', async () => {
  const { rerender } = render(AgentRuntimeActivityCard, { interaction: withCommands });
  expect(screen.getByText('Checking the configuration.')).toBeVisible();
  expect(screen.getByText('First I checked the tests.')).toBeVisible();
  expect(screen.getByText('Activity detail unavailable')).toBeVisible();
  expect(screen.queryByText('cat config/settings.yml…')).not.toBeInTheDocument();
  expect(screen.queryByText('git status · completed')).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Show commands', expanded: false }));
  expect(screen.getByText('cat config/settings.yml…')).toBeVisible();
  expect(screen.getByText('git status · completed')).toBeVisible();
  await rerender({ interaction: { ...withCommands, revision: 2 } });
  expect(screen.getByRole('button', { name: 'Hide commands', expanded: true })).toBeVisible();
  await fireEvent.click(screen.getByRole('button', { name: 'Hide commands' }));
  expect(screen.queryByText('git status · completed')).not.toBeInTheDocument();
});

test.each(['supported', 'unsupported', 'unknown', undefined])(
  'keeps commands compact when narration is %s and none has arrived',
  async (capability) => {
    const { container } = render(AgentRuntimeActivityCard, {
      interaction: {
        ...withCommands,
        snapshot: { ...withCommands.snapshot, narration_capability: capability, commentary: null },
        events: withCommands.events.filter((event) => event.type !== 'commentary.completed'),
      },
    });
    expect(screen.queryByText('cat config/settings.yml…')).not.toBeInTheDocument();
    expect(screen.queryByText('git status · completed')).not.toBeInTheDocument();
    const details = container.querySelector('details');
    expect(details.open).toBe(false);
    details.open = true;
    await fireEvent(details, new Event('toggle'));
    await fireEvent.click(screen.getByRole('button', { name: 'Show commands', expanded: false }));
    expect(screen.getByText('cat config/settings.yml…')).toBeVisible();
    expect(screen.getByText('git status · completed')).toBeVisible();
  }
);

test('keeps commands compact and expandable for opted-out residents', async () => {
  render(AgentRuntimeActivityCard, { interaction: { ...withCommands, narration_shared: false } });
  expect(screen.queryByText('cat config/settings.yml…')).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('button', { name: 'Show commands', expanded: false }));
  expect(screen.getByText('cat config/settings.yml…')).toBeVisible();
});

test('received narration takes precedence over stale capability metadata', async () => {
  const waiting = {
    ...withCommands,
    snapshot: { ...withCommands.snapshot, narration_capability: 'unsupported', commentary: null },
    events: [],
  };
  const { rerender } = render(AgentRuntimeActivityCard, { interaction: waiting });
  expect(screen.queryByText('cat config/settings.yml…')).not.toBeInTheDocument();
  await rerender({ interaction: { ...waiting, events: [withCommands.events[0]] } });
  expect(screen.getByText('First I checked the tests.')).toBeVisible();
  expect(screen.queryByText('cat config/settings.yml…')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Show commands' })).toBeVisible();
});

test('minimises on completion, remains present and can be expanded again', async () => {
  const { container, rerender } = render(AgentRuntimeActivityCard, { interaction: withCommands });
  const details = container.querySelector('details');
  expect(details.open).toBe(true);
  await rerender({
    interaction: {
      ...base,
      active: false,
      status: 'completed',
      status_label: 'finished',
      reply_label: '2 replies posted',
    },
  });
  expect(details.open).toBe(false);
  expect(screen.getByTestId('runtime-activity-card')).toBeInTheDocument();
  expect(screen.getByText(/2 replies posted/)).toBeInTheDocument();
  // jsdom does not implement the browser's native summary toggle default.
  details.open = true;
  await fireEvent(details, new Event('toggle'));
  expect(details.open).toBe(true);
});

test('completed cards start minimised and never expose diagnostic fields', () => {
  const { container } = render(AgentRuntimeActivityCard, {
    interaction: {
      ...base,
      active: false,
      status: 'completed',
      stdout: 'SECRET',
      stderr: 'SECRET',
      error_message: 'SECRET',
    },
  });
  expect(container.querySelector('details').open).toBe(false);
  expect(container.textContent).not.toContain('SECRET');
});

test('shows provider absence and lost reporting separately from execution failure', () => {
  render(AgentRuntimeActivityCard, {
    interaction: { ...base, reporter_health: 'stale', snapshot: { narration_capability: 'unsupported' } },
  });
  expect(screen.getByText(/Live updates interrupted/)).toBeInTheDocument();
  expect(screen.getByText(/Narration isn't available/)).toBeInTheDocument();
  expect(screen.getByText('is working')).toBeInTheDocument();
});

test('only narration automatically expands a working card and preserves manual collapse on updates', async () => {
  const { container, rerender } = render(AgentRuntimeActivityCard, { interaction: base });
  const details = container.querySelector('details');
  expect(details.open).toBe(false);
  await rerender({ interaction: { ...base, snapshot: { operations: withCommands.snapshot.operations } } });
  expect(details.open).toBe(false);
  await rerender({ interaction: withCommands });
  expect(details.open).toBe(true);
  details.open = false;
  await fireEvent(details, new Event('toggle'));
  await rerender({ interaction: { ...withCommands, revision: 3 } });
  expect(details.open).toBe(false);
});

test('historical narration does not expand a completed card', () => {
  const { container } = render(AgentRuntimeActivityCard, { interaction: { ...withCommands, active: false } });
  expect(container.querySelector('details').open).toBe(false);
});

test.each(['violet', 'emerald'])('keeps the %s resident background when work finishes', async (colour) => {
  const interaction = { ...withCommands, agent_colour: colour };
  const { container, rerender } = render(AgentRuntimeActivityCard, { interaction });
  const details = container.querySelector('details');
  expect(details).toHaveClass(`bg-${colour}-100`, `dark:bg-${colour}-900`);
  expect(details).not.toHaveClass('bg-muted/20');
  await rerender({ interaction: { ...interaction, active: false, status: 'completed' } });
  expect(details.open).toBe(false);
  expect(details).toHaveClass(`bg-${colour}-100`, `dark:bg-${colour}-900`);
});

test('uses a neutral background when no resident colour is available', () => {
  const { container } = render(AgentRuntimeActivityCard, { interaction: base });
  expect(container.querySelector('details')).toHaveClass('bg-muted/20');
});

test('historical completed cards use the resident background immediately', () => {
  const { container } = render(AgentRuntimeActivityCard, {
    interaction: { ...base, agent_colour: 'violet', active: false, status: 'completed' },
  });
  expect(container.querySelector('details')).toHaveClass('bg-violet-100', 'dark:bg-violet-900');
});

test('helper activity stays compact and narration opt-out hides all helper UI', async () => {
  const interaction = {
    ...base,
    narration_shared: true,
    snapshot: {
      subagents: [{ ordinal: 1, nickname: 'Donny', model: 'gpt-6.1-sol', status: 'running' }],
      subagents_overflow: 4,
    },
  };
  const { container, rerender } = render(AgentRuntimeActivityCard, { interaction });
  expect(container.querySelector('details').open).toBe(false);
  expect(screen.getByRole('img', { name: 'Donny · Working' })).toBeVisible();
  await rerender({ interaction: { ...interaction, narration_shared: false } });
  expect(screen.queryByRole('img', { name: /Donny/ })).not.toBeInTheDocument();
  expect(container.textContent).not.toContain('Donny');
  expect(container.textContent).not.toContain('+4 more');
});
