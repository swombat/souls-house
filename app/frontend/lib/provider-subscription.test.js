import { fireEvent, render, waitFor } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, expect, test, vi } from 'vitest';
import Harness from '../test/provider-subscription-harness.svelte';
import Panel from './components/agents/AgentProviderSubscriptionPanel.svelte';

const agent = { id: 'synthetic', name: 'Synthetic', provider: 'anthropic', available: false };
const response = (body) => ({ ok: true, json: async () => body });
function deferred() {
  let resolve;
  const promise = new Promise((finish) => (resolve = finish));
  return { promise, resolve: (body) => resolve(response(body)) };
}
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

test('closing during sign-in startup does not restart polling after the late response', async () => {
  vi.useFakeTimers();
  let finishStart;
  vi.stubGlobal(
    'fetch',
    vi.fn((url) => {
      if (url.endsWith('/cancel')) return Promise.resolve({ ok: true, json: async () => ({}) });
      return new Promise((resolve) => (finishStart = resolve));
    })
  );
  const view = render(Harness, { agent });
  const state = view.component.subscription;
  const starting = state.beginConnection();
  await state.cancelConnection();
  expect(state.connectOpen).toBe(false);
  finishStart({ ok: true, json: async () => ({ status: 'pending', user_code: 'synthetic-code' }) });
  await starting;
  const requests = fetch.mock.calls.length;
  await vi.advanceTimersByTimeAsync(10000);
  expect(fetch).toHaveBeenCalledTimes(requests);
  expect(state.ceremony).toBe(null);
  view.unmount();
});

test('unmount aborts pending subscription requests', async () => {
  let finish;
  vi.stubGlobal(
    'fetch',
    vi.fn(() => new Promise((resolve) => (finish = resolve)))
  );
  const view = render(Harness, { agent });
  const pending = view.component.subscription.beginConnection();
  const signal = fetch.mock.calls[0][1].signal;
  view.unmount();
  expect(signal.aborted).toBe(true);
  finish({ ok: true, json: async () => ({ status: 'pending' }) });
  await pending;
});

test('unchanged live edit props do not reload usage or capabilities', async () => {
  const connected = { ...agent, available: true, connection: { status: 'connected' } };
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ providers: { anthropic: { oauth_account: true } }, windows: [] }),
    })
  );
  const view = render(Harness, { agent: connected });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(fetch).toHaveBeenCalledTimes(2);
  for (let i = 0; i < 5; i++) await view.rerender({ agent: structuredClone(connected) });
  await view.rerender({ agent: { ...connected, name: 'Renamed' } });
  expect(fetch).toHaveBeenCalledTimes(2);
});

test('the rendered panel adopts idle persisted status, email, plan and mode without an auth status probe', async () => {
  vi.stubGlobal('fetch', vi.fn());
  const props = {
    account: { id: 'house' },
    subscriptionAgent: { ...agent, provider_name: 'Claude', connection: { status: 'expired' } },
    canManage: true,
  };
  const view = render(Panel, props);
  expect(view.getByText('No Claude subscription connected for clamping.')).toBeInTheDocument();
  await view.rerender({
    ...props,
    subscriptionAgent: {
      ...props.subscriptionAgent,
      auth_mode: 'oauth_account',
      connection: { status: 'connected', email: 'synthetic@example.test', plan: 'Synthetic plan' },
    },
  });
  expect(view.getByText('Connected as synthetic@example.test · Synthetic plan')).toBeInTheDocument();
  expect(view.getByRole('button', { name: 'Claude Code clamp' })).toBeInTheDocument();
  await view.rerender({ ...props, subscriptionAgent: { ...props.subscriptionAgent, connection: {} } });
  expect(view.queryByText(/Connected as/)).not.toBeInTheDocument();
  expect(fetch).not.toHaveBeenCalled();
});

test('rendered browser-code input survives a same-identity refresh without remounting the dialog', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn((url) =>
      Promise.resolve(
        response(
          url.includes('capabilities')
            ? { providers: { anthropic: { oauth_account: true } } }
            : { status: 'awaiting_code', verification_url: 'https://example.test/sign-in' }
        )
      )
    )
  );
  const props = {
    account: { id: 'house' },
    subscriptionAgent: { ...agent, available: true, provider_name: 'Claude' },
    canManage: true,
  };
  const view = render(Panel, props);
  await fireEvent.click(view.getByRole('button', { name: 'Connect Claude subscription' }));
  const input = await view.findByPlaceholderText('Paste the localhost callback URL or code');
  await fireEvent.input(input, { target: { value: 'synthetic-browser-code-draft' } });
  await view.rerender({
    ...props,
    subscriptionAgent: { ...props.subscriptionAgent, name: 'Refreshed elsewhere', auth_mode: 'api_key' },
  });
  expect(view.getByPlaceholderText('Paste the localhost callback URL or code')).toBe(input);
  expect(input).toHaveValue('synthetic-browser-code-draft');
  expect(fetch.mock.calls.filter(([, options]) => options?.method === 'POST')).toHaveLength(1);
});

test('live props preserve an open ceremony, browser-code draft and timer until explicit close', async () => {
  vi.useFakeTimers();
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue(
      response({
        status: 'awaiting_code',
        verification_url: 'https://example.test/sign-in',
        expires_at: new Date(Date.now() + 60000).toISOString(),
      })
    )
  );
  const view = render(Harness, { agent });
  await tick();
  const state = view.component.subscription;
  await state.beginConnection();
  state.browserCode = 'synthetic unfinished callback';
  await tick();
  const ceremony = state.ceremony;
  await view.rerender({ agent: { ...agent, name: 'Refreshed', connection: { status: 'expired' } } });
  expect(state.agent.name).toBe('Synthetic');
  expect(state.ceremony).toEqual(ceremony);
  expect(state.browserCode).toBe('synthetic unfinished callback');
  await vi.advanceTimersByTimeAsync(1000);
  expect(state.secondsRemaining).toBe(59);
  expect(fetch).toHaveBeenCalledTimes(1);
  await state.cancelConnection();
  await tick();
  expect(view.getByTestId('provider-name')).toHaveTextContent('Refreshed');
  expect(view.getByTestId('provider-status')).toHaveTextContent('expired');
  expect(state.browserCode).toBe('synthetic unfinished callback');
  const calls = fetch.mock.calls.length;
  await vi.advanceTimersByTimeAsync(10000);
  expect(fetch).toHaveBeenCalledTimes(calls);
});

test('deferred props reconcile after a mode mutation without undoing the newer successful action', async () => {
  const patch = deferred();
  vi.stubGlobal(
    'fetch',
    vi.fn(() => patch.promise)
  );
  const view = render(Harness, { agent });
  await tick();
  const state = view.component.subscription;
  const saving = state.setAuthMode('oauth_account');
  await view.rerender({ agent: { ...agent, name: 'Updated', auth_mode: 'api_key' } });
  expect(state.agent.name).toBe('Synthetic');
  expect(state.mutating).toBe(true);
  patch.resolve({});
  await saving;
  await tick();
  expect(state.agent.name).toBe('Updated');
  expect(state.agent.auth_mode).toBe('oauth_account');
  await view.rerender({ agent: { ...agent, name: 'Updated', auth_mode: 'api_key' } });
  expect(state.agent.auth_mode).toBe('api_key');
  await view.rerender({ agent: { ...agent, name: 'Updated again', auth_mode: 'api_key' } });
  expect(state.agent.auth_mode).toBe('api_key');
});

test('failed mode mutation drains deferred props and retains the local error', async () => {
  let reject;
  vi.stubGlobal(
    'fetch',
    vi.fn(() => new Promise((_, fail) => (reject = fail)))
  );
  const view = render(Harness, { agent });
  await tick();
  const state = view.component.subscription;
  const saving = state.setAuthMode('oauth_account');
  await view.rerender({ agent: { ...agent, name: 'Updated', auth_mode: 'api_key' } });
  reject(new Error('Synthetic refusal'));
  await saving;
  await tick();
  expect(state.agent.name).toBe('Updated');
  expect(state.actionError).toBe('Synthetic refusal');
});

test('successful ceremony completion keeps its newer connection while deferred props drain on close', async () => {
  vi.useFakeTimers();
  vi.stubGlobal(
    'fetch',
    vi.fn((url, options) =>
      Promise.resolve(
        response(
          options?.method === 'POST'
            ? { status: 'pending' }
            : { status: 'connected', email: 'finished@example.test', plan: 'Finished plan' }
        )
      )
    )
  );
  const view = render(Harness, { agent });
  await tick();
  const state = view.component.subscription;
  await state.beginConnection();
  await view.rerender({ agent: { ...agent, name: 'Deferred name', connection: { status: 'expired' } } });
  await vi.advanceTimersByTimeAsync(2000);
  expect(state.ceremony.status).toBe('connected');
  expect(state.agent.name).toBe('Synthetic');
  await state.cancelConnection();
  await tick();
  expect(state.agent.name).toBe('Deferred name');
  expect(state.agent.connection.email).toBe('finished@example.test');
  expect(state.agent.auth_mode).toBe('oauth_account');
  expect(fetch).toHaveBeenCalledTimes(2);
});

test('disconnect defers incoming props, then preserves its successful clearing over that older snapshot', async () => {
  const disconnect = deferred();
  vi.stubGlobal('confirm', () => true);
  vi.stubGlobal(
    'fetch',
    vi.fn(() => disconnect.promise)
  );
  const connected = { ...agent, connection: { status: 'connected' }, auth_mode: 'oauth_account' };
  const view = render(Harness, { agent: connected });
  await tick();
  const state = view.component.subscription;
  const removing = state.disconnectSubscription();
  await view.rerender({ agent: { ...connected, name: 'Deferred name' } });
  expect(state.agent.name).toBe('Synthetic');
  disconnect.resolve({});
  await removing;
  await tick();
  expect(state.agent.name).toBe('Deferred name');
  expect(state.agent.connection).toEqual({});
  expect(state.agent.auth_mode).toBe('api_key');
});

test.each(['mode', 'disconnect', 'start', 'code', 'poll'])(
  'late %s response cannot modify a replacement provider identity',
  async (operation) => {
    vi.useFakeTimers();
    vi.stubGlobal('confirm', () => true);
    const late = deferred();
    const mock = vi.fn(() => late.promise);
    vi.stubGlobal('fetch', mock);
    const view = render(Harness, { agent });
    await tick();
    const state = view.component.subscription;
    let request;
    if (operation === 'mode') request = state.setAuthMode('oauth_account');
    if (operation === 'disconnect') request = state.disconnectSubscription();
    if (['code', 'poll'].includes(operation)) {
      mock.mockResolvedValueOnce(response({ status: 'awaiting_code' }));
      await state.beginConnection();
      state.browserCode = 'old-identity-code';
      if (operation === 'code') request = state.submitBrowserCode();
      else await vi.advanceTimersByTimeAsync(2000);
    }
    if (operation === 'start') request = state.beginConnection();
    await view.rerender({ agent: { ...agent, id: 'replacement', provider: 'openai', name: 'Replacement' } });
    expect(state.connectOpen).toBe(false);
    expect(state.browserCode).toBe('');
    late.resolve({ status: 'connected', email: 'obsolete@example.test' });
    await request;
    await tick();
    expect(state.agent.id).toBe('replacement');
    expect(state.agent.connection).toBeUndefined();
    expect(state.ceremony).toBe(null);
    expect(state.actionError).toBe(null);
    const calls = mock.mock.calls.length;
    await vi.advanceTimersByTimeAsync(10000);
    expect(mock).toHaveBeenCalledTimes(calls);
    expect(mock.mock.calls.some(([url]) => url.endsWith('/cancel'))).toBe(false);
  }
);

test.each([null, { ...agent, provider: 'unsupported' }])(
  'removed or unsupported presentation closes safely with no automatic cancellation',
  async (next) => {
    const late = deferred();
    vi.stubGlobal(
      'fetch',
      vi.fn(() => late.promise)
    );
    const view = render(Harness, { agent });
    await tick();
    const state = view.component.subscription;
    const starting = state.beginConnection();
    await view.rerender({ agent: next });
    expect(state.valid).toBe(false);
    expect(state.connectOpen).toBe(false);
    late.resolve({ status: 'pending' });
    await starting;
    await state.beginConnection();
    await state.setAuthMode('api_key');
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(state.ceremony).toBe(null);
  }
);

test('account changes invalidate startup even for the same resident id and provider', async () => {
  const late = deferred();
  vi.stubGlobal(
    'fetch',
    vi.fn(() => late.promise)
  );
  const view = render(Harness, { agent });
  await tick();
  const state = view.component.subscription;
  const starting = state.beginConnection();
  await view.rerender({ agent, account: { id: 'other-account' } });
  late.resolve({ status: 'pending' });
  await starting;
  expect(state.connectOpen).toBe(false);
  expect(state.ceremony).toBe(null);
});

test('capabilities and usage ignore late success from an old identity', async () => {
  const capability = deferred();
  const usage = deferred();
  vi.stubGlobal(
    'fetch',
    vi.fn((url) => (url.includes('capabilities') ? capability.promise : usage.promise))
  );
  const connected = { ...agent, available: true, connection: { status: 'connected' } };
  const view = render(Harness, { agent: connected });
  await tick();
  expect(fetch).toHaveBeenCalledTimes(2);
  await view.rerender({ agent: { ...agent, id: 'replacement' } });
  capability.resolve({ providers: { anthropic: { oauth_account: false } } });
  usage.resolve({ windows: [{ id: 'obsolete' }] });
  await tick();
  await tick();
  const state = view.component.subscription;
  expect(state.capabilityChecked).toBe(false);
  expect(state.subscriptionSupported).toBe(true);
  expect(state.usage).toBe(null);
  expect(state.usageLoading).toBe(false);
});

test('late capability/usage errors cannot replace the current identity state', async () => {
  const failures = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(() => new Promise((_, reject) => failures.push(reject)))
  );
  const view = render(Harness, {
    agent: { ...agent, available: true, connection: { status: 'connected' } },
  });
  await tick();
  await view.rerender({ agent: { ...agent, id: 'replacement' } });
  failures.forEach((reject) => reject(new Error('obsolete failure')));
  await tick();
  await tick();
  expect(view.component.subscription.usageError).toBe(null);
  expect(view.component.subscription.capabilityChecked).toBe(false);
});

test('submitting a code preserves a newer browser draft and ignores a pre-submit poll', async () => {
  vi.useFakeTimers();
  const poll = deferred();
  const submit = deferred();
  vi.stubGlobal(
    'fetch',
    vi.fn((url, options) => {
      if (url.endsWith('/code')) return submit.promise;
      if (options?.method === 'POST') return Promise.resolve(response({ status: 'awaiting_code' }));
      return poll.promise;
    })
  );
  const view = render(Harness, { agent });
  await tick();
  const state = view.component.subscription;
  await state.beginConnection();
  state.browserCode = 'submitted synthetic code';
  await vi.advanceTimersByTimeAsync(2000);
  const sending = state.submitBrowserCode();
  state.browserCode = 'newer unsubmitted draft';
  await view.rerender({ agent: { ...agent, name: 'Deferred' } });
  submit.resolve({ status: 'finalizing' });
  await sending;
  poll.resolve({ status: 'expired' });
  await tick();
  await tick();
  expect(state.ceremony.status).toBe('finalizing');
  expect(state.browserCode).toBe('newer unsubmitted draft');
  expect(state.agent.name).toBe('Synthetic');
});

test('latest manual usage request wins and model changes invalidate old usage', async () => {
  const requests = [];
  vi.stubGlobal(
    'fetch',
    vi.fn((url) => {
      if (url.includes('capabilities')) return Promise.resolve(response({}));
      const request = deferred();
      requests.push(request);
      return request.promise;
    })
  );
  const connected = { ...agent, available: true, model: 'first', connection: { status: 'connected' } };
  const view = render(Harness, { agent: connected });
  await tick();
  const state = view.component.subscription;
  const refresh = state.loadUsage(true);
  requests[1].resolve({ marker: 'newer' });
  await refresh;
  requests[0].resolve({ marker: 'older' });
  await tick();
  await tick();
  expect(state.usage.marker).toBe('newer');
  await view.rerender({ agent: { ...connected, model: 'second' } });
  expect(state.usage).toBe(null);
  requests[2].resolve({ marker: 'second-model' });
  await waitFor(() => expect(state.usage?.marker).toBe('second-model'));
});
