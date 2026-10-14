import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

const reload = vi.fn();
vi.mock('@inertiajs/svelte', () => ({ router: { reload: (...args) => reload(...args), patch: vi.fn() } }));
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(() => Promise.resolve('data:image/png;base64,QR')) } }));

const { default: ConnectionTelegramLogin } = await import('./connection-telegram-login.svelte');

function reply(status, body) {
  return Promise.resolve({ ok: status < 400, status, json: () => Promise.resolve(body) });
}

function mount(connection = {}, props = {}) {
  return render(ConnectionTelegramLogin, {
    account: { id: 'house' },
    connection: { id: 'svc_tg', provider: 'telegram', status: 'pairing', ...connection },
    pollInterval: 60_000,
    ...props,
  });
}

function qrPairing(extra = {}) {
  const expires = new Date(Date.now() + 90_000).toISOString();
  return {
    status: 'pairing',
    generation: 3,
    qr: { code: 'tg://login?token=x', expires_at: expires },
    login: {},
    ...extra,
  };
}

function bodyOf(path) {
  const call = globalThis.fetch.mock.calls.find(([url]) => url.endsWith(path));
  return call && JSON.parse(call[1].body);
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

  it('offers no tg://login link to tap: Telegram refuses it on the phone it would approve', async () => {
    const expires = new Date(Date.now() + 90_000).toISOString();
    globalThis.fetch = vi.fn(() =>
      reply(200, { status: 'pairing', qr: { code: 'tg://login?token=abc_-', expires_at: expires }, login: {} })
    );
    const { container } = mount();
    await screen.findByAltText('Telegram sign-in QR code');
    expect(screen.queryByText('Open in Telegram')).not.toBeInTheDocument();
    expect(container.querySelector('a[href^="tg:"]')).toBeNull();
    expect(screen.getByRole('button', { name: 'Sign in with your phone number instead' })).toBeInTheDocument();
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
        : reply(200, { status: 'pairing', qr: null, generation: 7, login: { step: 'password', hint: 'tea' } })
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
    expect(JSON.parse(options.body)).toEqual({ password: 'secret words', generation: 7 });
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

  describe('with the phone number instead of the QR', () => {
    it('sends the number, then the code, with fetch, and never keeps the code in the field', async () => {
      document.head.innerHTML = '<meta name="csrf-token" content="tok">';
      globalThis.fetch = vi.fn((url) => {
        if (url.endsWith('/login/phone'))
          return reply(200, {
            outcome: 'code_sent',
            login: { step: 'code', delivery: 'app', length: 5 },
            generation: 3,
          });
        if (url.endsWith('/login/code')) return reply(200, { outcome: 'code_invalid' });
        return reply(200, qrPairing());
      });
      mount();
      await fireEvent.click(await screen.findByRole('button', { name: 'Sign in with your phone number instead' }));
      const phone = screen.getByLabelText('Phone number');
      expect(phone).toHaveAttribute('type', 'tel');
      expect(phone).toHaveAttribute('autocomplete', 'tel');
      expect(screen.getByText(/International format/)).toBeInTheDocument();
      await fireEvent.input(phone, { target: { value: '+44 7700 900123' } });
      await fireEvent.click(screen.getByRole('button', { name: 'Send the code' }));

      expect(await screen.findByTestId('telegram-code-sent')).toHaveTextContent(
        'Telegram sent a code to your Telegram app.'
      );
      expect(bodyOf('/login/phone')).toEqual({ phone: '+44 7700 900123', generation: 3 });
      const [, options] = globalThis.fetch.mock.calls.find(([url]) => url.endsWith('/login/phone'));
      expect(options.headers['X-CSRF-Token']).toBe('tok');
      expect(screen.queryByAltText('Telegram sign-in QR code')).not.toBeInTheDocument();

      const code = screen.getByLabelText('Login code');
      expect(code).toHaveAttribute('autocomplete', 'one-time-code');
      expect(code).toHaveAttribute('inputmode', 'numeric');
      await fireEvent.input(code, { target: { value: ' 12345 ' } });
      await fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
      expect(await screen.findByText('That code was not right. Check it and try again.')).toBeInTheDocument();
      expect(bodyOf('/login/code')).toEqual({ code: '12345', generation: 3 });
      expect(code.value).toBe('');
    });

    it('leads with the phone number on a small screen, the QR folded away for a computer', async () => {
      globalThis.fetch = vi.fn(() => reply(200, qrPairing()));
      mount({}, { phoneFirst: true });
      expect(await screen.findByLabelText('Phone number')).toBeInTheDocument();
      const elsewhere = await screen.findByTestId('telegram-qr-elsewhere');
      expect(elsewhere).toHaveTextContent('Signing in from a computer? Show the QR code');
      expect(elsewhere.tagName).toBe('DETAILS');
      expect(screen.queryByRole('button', { name: 'Sign in with your phone number instead' })).not.toBeInTheDocument();
    });

    it('keeps the number for a correction when Telegram does not accept it', async () => {
      globalThis.fetch = vi.fn((url) =>
        url.endsWith('/login/phone') ? reply(200, { outcome: 'phone_invalid' }) : reply(200, qrPairing())
      );
      mount({}, { phoneFirst: true });
      const phone = await screen.findByLabelText('Phone number');
      await fireEvent.input(phone, { target: { value: '07700 900123' } });
      await fireEvent.click(screen.getByRole('button', { name: 'Send the code' }));
      expect(await screen.findByText(/Enter it in international format/)).toBeInTheDocument();
      expect(phone.value).toBe('07700 900123');
    });

    it('goes on to the two-step password after the code', async () => {
      globalThis.fetch = vi.fn((url) =>
        url.endsWith('/login/code')
          ? reply(200, { outcome: 'password_required' })
          : reply(200, qrPairing({ qr: null, login: { step: 'code', delivery: 'sms' } }))
      );
      mount();
      expect(await screen.findByTestId('telegram-code-sent')).toHaveTextContent('Telegram sent a code by SMS.');
      await fireEvent.input(screen.getByLabelText('Login code'), { target: { value: '12345' } });
      await fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
      expect(await screen.findByLabelText('Telegram password')).toBeInTheDocument();
      expect(screen.getByText(/also has a two-step password/)).toBeInTheDocument();
    });

    it('asks for the number again to send a new code after a reload', async () => {
      globalThis.fetch = vi.fn(() => reply(200, qrPairing({ qr: null, login: { step: 'code', delivery: 'app' } })));
      mount();
      await fireEvent.click(await screen.findByRole('button', { name: 'Send a new code' }));
      expect(await screen.findByLabelText('Phone number')).toBeInTheDocument();
      expect(globalThis.fetch.mock.calls.some(([url]) => url.endsWith('/login/phone'))).toBe(false);
    });

    it('sends a new code to the same number without asking again', async () => {
      globalThis.fetch = vi.fn((url) => {
        if (url.endsWith('/login/phone'))
          return reply(200, { outcome: 'code_sent', login: { step: 'code', delivery: 'app' } });
        if (url.endsWith('/login/code')) return reply(200, { outcome: 'code_expired' });
        return reply(200, qrPairing());
      });
      mount({}, { phoneFirst: true });
      await fireEvent.input(await screen.findByLabelText('Phone number'), { target: { value: '+34 612 345 678' } });
      await fireEvent.click(screen.getByRole('button', { name: 'Send the code' }));
      await fireEvent.input(await screen.findByLabelText('Login code'), { target: { value: '1' } });
      await fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
      expect(await screen.findByText('That code expired. Send a new one.')).toBeInTheDocument();
      await fireEvent.click(screen.getByRole('button', { name: 'Send a new code' }));
      await waitFor(() =>
        expect(globalThis.fetch.mock.calls.filter(([url]) => url.endsWith('/login/phone'))).toHaveLength(2)
      );
      const last = globalThis.fetch.mock.calls.filter(([url]) => url.endsWith('/login/phone')).at(-1);
      expect(JSON.parse(last[1].body).phone).toBe('+34 612 345 678');
    });
  });
});
