import { cleanup, render, screen } from '@testing-library/svelte';
import AgentTriggerBar from './AgentTriggerBar.svelte';

// Closing the credentials dialog makes bits-ui schedule its body-scroll-lock
// cleanup on a 24 ms timer. Let it run while this file's DOM still exists;
// otherwise it can fire after teardown and fail the run with
// "document is not defined" (seen in #97's CI, not caused by the test itself).
afterAll(async () => {
  cleanup();
  await new Promise((resolve) => setTimeout(resolve, 100));
});

test('keeps retired participants visible but unavailable alongside a paused offline harness', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      { id: 'old', name: 'Old resident', deprecated: true, unavailability_reason: 'agent_deprecated' },
      { id: 'current', name: 'Current resident', runtime: 'offline', active: true, paused: true },
    ],
  });
  expect(screen.getByRole('button', { name: 'Old resident' })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Old resident' })).toHaveAttribute(
    'title',
    'Old resident · Deprecated · Unavailable'
  );
  expect(screen.getByRole('button', { name: 'Current resident' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Ask All' })).toBeEnabled();
});

test('disables Ask All when no participant is available', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      { id: 'old', name: 'Old resident', unavailability_reason: 'agent_deprecated' },
      { id: 'new', name: 'Starting resident', unavailability_reason: 'agent_provisioning' },
    ],
  });
  expect(screen.getByRole('button', { name: 'Ask All' })).toBeDisabled();
});

// Server-authoritative checks avoid stale credential flags in long-lived chats.
test('shows credential setup links and clears the spinner after a rejected trigger', async () => {
  const { fireEvent, waitFor } = await import('@testing-library/svelte');
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok: false,
    json: async () => ({
      code: 'missing_credentials',
      error: 'Edit the resident and set up credentials.',
      agents: [{ id: 'resident', name: 'Resident' }],
    }),
  });
  try {
    const onTrigger = vi.fn();
    render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [{ id: 'resident', name: 'Resident' }],
      onTrigger,
    });
    await fireEvent.click(screen.getByRole('button', { name: 'Resident' }));
    expect(await screen.findByRole('dialog')).toHaveTextContent('Set up resident credentials');
    expect(screen.getByRole('link', { name: 'Edit Resident' })).toHaveAttribute(
      'href',
      '/accounts/account/residents/resident/edit'
    );
    expect(onTrigger).not.toHaveBeenCalled();
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ agent_id: 'resident' });
    await fireEvent.click(screen.getByRole('button', { name: 'Not now', exact: true }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'Resident' })).toBeEnabled());
  } finally {
    fetchMock.mockRestore();
  }
});

test('Ask All reports every blocked resident without leaving a pending state', async () => {
  const { fireEvent } = await import('@testing-library/svelte');
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok: false,
    json: async () => ({
      code: 'missing_credentials',
      error: 'Set up credentials.',
      agents: [
        { id: 'one', name: 'One' },
        { id: 'two', name: 'Two' },
      ],
    }),
  });
  try {
    render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [
        { id: 'one', name: 'One' },
        { id: 'two', name: 'Two' },
      ],
    });
    await fireEvent.click(screen.getByRole('button', { name: 'Ask All' }));
    expect(await screen.findByRole('link', { name: 'Edit One' })).toBeVisible();
    expect(screen.getByRole('link', { name: 'Edit Two' })).toBeVisible();
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({});
  } finally {
    fetchMock.mockRestore();
  }
});

test('a successful trigger notifies the parent and waits for a response', async () => {
  const { fireEvent, waitFor } = await import('@testing-library/svelte');
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({ ok: true });
  try {
    const onTrigger = vi.fn();
    const { rerender } = render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [{ id: 'one', name: 'One' }],
      onTrigger,
    });
    await fireEvent.click(screen.getByRole('button', { name: 'One' }));
    await waitFor(() => expect(onTrigger).toHaveBeenCalledOnce());
    expect(screen.getByRole('button', { name: 'One' })).toBeDisabled();
    await rerender({ responseMarker: 'new-reply' });
    await waitFor(() => expect(screen.getByRole('button', { name: 'One' })).toBeEnabled());
  } finally {
    fetchMock.mockRestore();
  }
});

test('a network failure releases the trigger and gives a retryable error', async () => {
  const { fireEvent, waitFor } = await import('@testing-library/svelte');
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Network unavailable'));
  try {
    render(AgentTriggerBar, { accountId: 'account', chatId: 'chat', agents: [{ id: 'one', name: 'One' }] });
    await fireEvent.click(screen.getByRole('button', { name: 'One' }));
    expect(await screen.findByRole('dialog')).toHaveTextContent('Network unavailable');
    expect(screen.queryByRole('link')).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Not now' }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'One' })).toBeEnabled());
  } finally {
    fetchMock.mockRestore();
  }
});

test('shows setup instructions before an automatic wake needs the manual button', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      {
        id: 'resident',
        name: 'Resident',
        inference_setup_message: 'Edit the resident and set up credentials before asking them to respond.',
      },
    ],
  });
  expect(screen.getByRole('status')).toHaveTextContent('set up credentials');
  expect(screen.getByRole('link', { name: 'Edit Resident' })).toHaveAttribute(
    'href',
    '/accounts/account/residents/resident/edit'
  );
});
