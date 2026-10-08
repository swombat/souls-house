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

const selection = (overrides = {}) => ({
  model_id: 'openai/gpt-6.1-sol',
  label: 'GPT-6.1 Sol',
  default_model_id: 'openai/gpt-6.1-sol',
  default_label: 'GPT-6.1 Sol',
  selected_by_conversation: false,
  reasoning_effort: 'default',
  problem: null,
  choices: [
    { model_id: 'openai/gpt-6.1-sol', label: 'GPT-6.1 Sol' },
    { model_id: 'openai/gpt-6-astra', label: 'GPT-6 Astra' },
  ],
  ...overrides,
});

const modelTrigger = (name) => screen.getByRole('button', { name: new RegExp(`^Model for ${name}:`) });

async function openModelMenu(name) {
  const { fireEvent } = await import('@testing-library/svelte');
  const trigger = modelTrigger(name);
  await fireEvent.pointerDown(trigger, { button: 0, pointerType: 'mouse' });
  if (!screen.queryByRole('menu')) await fireEvent.keyDown(trigger, { key: 'Enter' });
  return screen.findByRole('menu');
}

test('no model control when the resident has only its default and nothing selected', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      {
        id: 'one',
        name: 'One',
        model_selection: selection({ choices: [{ model_id: 'openai/gpt-6.1-sol', label: 'GPT-6.1 Sol' }] }),
      },
    ],
  });
  expect(screen.queryByRole('button', { name: /^Model for One:/ })).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'One' })).toBeEnabled();
});

test('shows the model the next turn will use, with the default offered as an explicit choice', async () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [{ id: 'one', name: 'One', model_selection: selection() }],
  });
  expect(modelTrigger('One')).toHaveTextContent('GPT-6.1 Sol');
  const menu = await openModelMenu('One');
  const items = Array.from(menu.querySelectorAll('[role="menuitemradio"]')).map((el) => el.textContent.trim());
  expect(items).toEqual(['Use resident default (GPT-6.1 Sol)', 'GPT-6.1 Sol', 'GPT-6 Astra']);
  expect(screen.getByRole('menuitemradio', { name: 'Use resident default (GPT-6.1 Sol)' })).toHaveAttribute(
    'aria-checked',
    'true'
  );
});

test('while a turn runs, says what is running now and what is selected next as two facts', () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    activeRuntimeAgentIds: ['one'],
    runtimeInteractions: [
      { id: 'old', agent_id: 'one', active: false, model_label: 'GPT-5.5' },
      { id: 'now', agent_id: 'one', active: true, model_label: 'GPT-6.1 Sol' },
    ],
    agents: [
      {
        id: 'one',
        name: 'One',
        model_selection: selection({
          model_id: 'openai/gpt-6-astra',
          label: 'GPT-6 Astra',
          selected_by_conversation: true,
        }),
      },
    ],
  });
  const trigger = modelTrigger('One');
  expect(trigger).toHaveTextContent('Next: GPT-6 Astra');
  expect(trigger).toHaveAttribute('title', 'Running now on GPT-6.1 Sol; GPT-6 Astra selected for the next turn');
  expect(trigger).toBeEnabled();
});

test('choosing a model PATCHes the selection and shows the server response', async () => {
  const { fireEvent, waitFor } = await import('@testing-library/svelte');
  document.head.innerHTML = '<meta name="csrf-token" content="token-123">';
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok: true,
    json: async () => ({
      model_selection: selection({
        model_id: 'openai/gpt-6-astra',
        label: 'GPT-6 Astra',
        selected_by_conversation: true,
      }),
    }),
  });
  try {
    render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [{ id: 'one', name: 'One', model_selection: selection() }],
    });
    await openModelMenu('One');
    await fireEvent.click(screen.getByRole('menuitemradio', { name: 'GPT-6 Astra' }));
    await waitFor(() => expect(modelTrigger('One')).toHaveTextContent('GPT-6 Astra'));
    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('/accounts/account/chats/chat/model_selection');
    expect(options.method).toBe('PATCH');
    expect(options.headers['X-CSRF-Token']).toBe('token-123');
    expect(JSON.parse(options.body)).toEqual({ agent_id: 'one', model_id: 'openai/gpt-6-astra' });
  } finally {
    fetchMock.mockRestore();
    document.head.innerHTML = '';
  }
});

// Cross-client: another browser or the resident itself changes the model.
// The room reloads `agents` on its channel; the bar must show that newer
// selection, even over a value this browser saved earlier, and must still let
// this person pick the model it had shown as current.
test('a selection changed elsewhere replaces what this browser saved, and can be re-chosen', async () => {
  const { fireEvent, waitFor } = await import('@testing-library/svelte');
  const astra = selection({
    model_id: 'openai/gpt-6-astra',
    label: 'GPT-6 Astra',
    selected_by_conversation: true,
    seat_model_id: 'openai/gpt-6-astra',
  });
  const sol = selection({
    model_id: 'openai/gpt-6.1-sol',
    label: 'GPT-6.1 Sol',
    selected_by_conversation: false,
    seat_model_id: 'openai/gpt-6.1-sol',
  });
  const fetchMock = vi
    .spyOn(globalThis, 'fetch')
    .mockResolvedValue({ ok: true, json: async () => ({ model_selection: astra }) });
  try {
    const { rerender } = render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [{ id: 'one', name: 'One', model_selection: selection() }],
    });
    await openModelMenu('One');
    await fireEvent.click(screen.getByRole('menuitemradio', { name: 'GPT-6 Astra' }));
    await waitFor(() => expect(modelTrigger('One')).toHaveTextContent('GPT-6 Astra'));

    // Someone else pins Sol; the room's agents prop reloads with it.
    await rerender({ agents: [{ id: 'one', name: 'One', model_selection: sol }] });
    expect(modelTrigger('One')).toHaveTextContent('GPT-6.1 Sol');

    // This browser may still be stale (the server could hold another model by
    // now). Picking the model it shows as current must still reach the server.
    await openModelMenu('One');
    await fireEvent.click(screen.getByRole('menuitemradio', { name: 'GPT-6.1 Sol' }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ agent_id: 'one', model_id: 'openai/gpt-6.1-sol' });
  } finally {
    fetchMock.mockRestore();
  }
});

test('the effective reasoning effort is shown in the model details', async () => {
  render(AgentTriggerBar, {
    accountId: 'account',
    chatId: 'chat',
    agents: [
      {
        id: 'one',
        name: 'One',
        model_selection: selection({
          model_id: 'openai/gpt-6-astra',
          label: 'GPT-6 Astra',
          selected_by_conversation: true,
          reasoning_effort: 'medium',
        }),
      },
    ],
  });
  await openModelMenu('One');
  expect(screen.getByTestId('model-effort')).toHaveTextContent("Reasoning effort: medium (GPT-6 Astra's default)");
});

test('a refused selection shows the server error', async () => {
  const { fireEvent } = await import('@testing-library/svelte');
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok: false,
    status: 422,
    json: async () => ({ error: "GPT-6 Astra is not on One's list of models for conversations" }),
  });
  try {
    render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [{ id: 'one', name: 'One', model_selection: selection() }],
    });
    await openModelMenu('One');
    await fireEvent.click(screen.getByRole('menuitemradio', { name: 'GPT-6 Astra' }));
    const dialog = await screen.findByRole('dialog');
    expect(dialog).toHaveTextContent("Unable to change One's model");
    expect(dialog).toHaveTextContent("GPT-6 Astra is not on One's list of models for conversations");
    expect(modelTrigger('One')).toHaveTextContent('GPT-6.1 Sol');
  } finally {
    fetchMock.mockRestore();
  }
});

test('a selection that cannot be used is shown visibly with the default one click away', async () => {
  const { fireEvent, waitFor } = await import('@testing-library/svelte');
  const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue({
    ok: true,
    json: async () => ({ model_selection: selection() }),
  });
  try {
    render(AgentTriggerBar, {
      accountId: 'account',
      chatId: 'chat',
      agents: [
        {
          id: 'one',
          name: 'One',
          model_selection: selection({
            model_id: 'openai/gpt-5.5',
            label: 'GPT-5.5',
            selected_by_conversation: true,
            problem: "GPT-5.5 is not on One's list of models for conversations",
          }),
        },
      ],
    });
    expect(screen.getByRole('status')).toHaveTextContent(
      "One: GPT-5.5 is not on One's list of models for conversations."
    );
    await fireEvent.click(screen.getByRole('button', { name: 'Use resident default (GPT-6.1 Sol)' }));
    await waitFor(() => expect(screen.queryByRole('status')).not.toBeInTheDocument());
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ agent_id: 'one', model_id: 'default' });
    expect(modelTrigger('One')).toHaveTextContent('GPT-6.1 Sol');
  } finally {
    fetchMock.mockRestore();
  }
});
