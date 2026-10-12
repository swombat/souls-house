import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

const reload = vi.fn();
vi.mock('@inertiajs/svelte', () => ({ router: { reload: (...args) => reload(...args), patch: vi.fn() } }));
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(() => Promise.resolve('data:image/png;base64,QR')) } }));

const { default: ConnectionTelegramLogin } = await import('./connection-telegram-login.svelte');

function reply(status, body) {
  return Promise.resolve({ ok: status < 400, status, json: () => Promise.resolve(body) });
}

function mount(connection = {}) {
  return render(ConnectionTelegramLogin, {
    account: { id: 'house' },
    connection: { id: 'svc_tg', provider: 'telegram', status: 'pairing', ...connection },
    pollInterval: 60_000,
  });
}

afterEach(() => {
  vi.restoreAllMocks();
  reload.mockReset();
  document.head.innerHTML = '';
});

describe('Telegram sign-in', () => {
  it('shows the QR code, the steps and a countdown to the expiry', async () => {
    const expires = new Date(Date.now() + 90_000).toISOString();
    globalThis.fetch = vi.fn(() =>
      reply(200, { status: 'pairing', qr: { code: 'tg://login?token=x', expires_at: expires }, login: {} })
    );
    mount();
    expect(await screen.findByAltText('Telegram sign-in QR code')).toHaveAttribute('src', 'data:image/png;base64,QR');
    expect(screen.getByText(/Link Desktop Device/)).toBeInTheDocument();
    expect(screen.getByTestId('telegram-qr-countdown')).toHaveTextContent(/expires in 1:(29|30)/);
    expect(globalThis.fetch).toHaveBeenCalledWith(
      '/accounts/house/service_connections/svc_tg/pairing',
      expect.anything()
    );
  });

  it('tells someone who is not the owner to wait, and stops asking', async () => {
    globalThis.fetch = vi.fn(() => reply(404, {}));
    mount();
    expect(await screen.findByText('Waiting for the person who connected it to sign in.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Restart sign-in' })).not.toBeInTheDocument();
    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
  });

  it('sends the password with fetch and CSRF, clears it, and says what happened', async () => {
    document.head.innerHTML = '<meta name="csrf-token" content="tok">';
    globalThis.fetch = vi.fn((url) =>
      url.endsWith('/login/password')
        ? reply(200, { outcome: 'not_configured' })
        : reply(200, { status: 'pairing', qr: null, login: { step: 'password', hint: 'tea' } })
    );
    mount();
    const input = await screen.findByLabelText('Telegram password');
    expect(input).toHaveAttribute('type', 'password');
    expect(input).toHaveAttribute('autocomplete', 'current-password');
    expect(screen.getByText('Hint: tea')).toBeInTheDocument();
    await fireEvent.input(input, { target: { value: 'secret words' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(await screen.findByText(/connector is not set up/)).toBeInTheDocument();
    expect(input.value).toBe('');
    const [url, options] = globalThis.fetch.mock.calls.find(([u]) => u.endsWith('/login/password'));
    expect(url).toBe('/accounts/house/service_connections/svc_tg/login/password');
    expect(options.method).toBe('POST');
    expect(options.headers['X-CSRF-Token']).toBe('tok');
    expect(JSON.parse(options.body)).toEqual({ password: 'secret words' });
  });

  it('explains a failure in plain words and offers a restart', async () => {
    globalThis.fetch = vi.fn((url) =>
      url.endsWith('/login/restart')
        ? reply(200, { status: 'pairing', login: {} })
        : reply(200, { status: 'pairing', qr: null, login: { error: 'flood_wait', retry_after: 30 } })
    );
    mount();
    expect(await screen.findByText('Telegram asked us to wait 30 seconds.')).toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Restart sign-in' }));
    expect(await screen.findByText('Waiting for a sign-in code from Telegram.')).toBeInTheDocument();
  });

  it('reloads the page once the connection is signed in', async () => {
    globalThis.fetch = vi.fn(() => reply(200, { status: 'connected', qr: null, login: {} }));
    mount();
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
  });
});
