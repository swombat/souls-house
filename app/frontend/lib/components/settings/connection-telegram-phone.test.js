import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

const { default: TelegramPhoneSignIn } = await import('./connection-telegram-phone.svelte');

const base = '/accounts/house/service_connections/svc_tg';

function reply(status, body) {
  return Promise.resolve({ ok: status < 400, status, json: () => Promise.resolve(body) });
}

function mount(props = {}) {
  const onlogin = vi.fn();
  const onnotice = vi.fn();
  const result = render(TelegramPhoneSignIn, { base, generation: 7, login: {}, onlogin, onnotice, ...props });
  return { ...result, onlogin, onnotice };
}

function posts(path) {
  return globalThis.fetch.mock.calls.filter(([url]) => url === `${base}${path}`).map(([, o]) => JSON.parse(o.body));
}

afterEach(() => vi.restoreAllMocks());

describe('Telegram phone-number sign-in', () => {
  it('sends the number for this attempt and hands the code step up', async () => {
    globalThis.fetch = vi.fn(() => reply(200, { outcome: 'code_sent', login: { step: 'code', delivery: 'app' } }));
    const { onlogin, onnotice } = mount();
    await fireEvent.input(screen.getByLabelText('Phone number'), { target: { value: '+44 7700 900123' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Send the code' }));
    await waitFor(() => expect(onlogin).toHaveBeenCalledWith({ step: 'code', delivery: 'app' }));
    expect(posts('/login/phone')).toEqual([{ phone: '+44 7700 900123', generation: 7 }]);
    expect(onnotice).toHaveBeenLastCalledWith(null);
    expect(screen.getByLabelText('Phone number').value).toBe('');
  });

  it('offers the QR only when the parent has one to go back to', async () => {
    mount();
    expect(screen.queryByRole('button', { name: 'Show the QR code' })).not.toBeInTheDocument();
    const onshowqr = vi.fn();
    mount({ onshowqr });
    await fireEvent.click(screen.getByRole('button', { name: 'Show the QR code' }));
    expect(onshowqr).toHaveBeenCalledOnce();
  });

  it('sends the code, clears the field and goes on to the password', async () => {
    globalThis.fetch = vi.fn(() => reply(200, { outcome: 'password_required' }));
    const { onlogin, onnotice } = mount({ login: { step: 'code', delivery: 'sms' } });
    expect(screen.getByTestId('telegram-code-sent')).toHaveTextContent('Telegram sent a code by SMS.');
    const code = screen.getByLabelText('Login code');
    await fireEvent.input(code, { target: { value: ' 12345 ' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
    await waitFor(() => expect(onlogin).toHaveBeenCalledWith({ step: 'password' }));
    expect(posts('/login/code')).toEqual([{ code: '12345', generation: 7 }]);
    expect(code.value).toBe('');
    expect(onnotice.mock.calls.at(-1)[0].text).toMatch(/two-step password/);
  });

  it('says the earlier code stands when Telegram cannot send another, and offers no QR', async () => {
    globalThis.fetch = vi.fn((url) =>
      url.endsWith('/login/phone')
        ? reply(200, { outcome: posts('/login/phone').length > 1 ? 'unsupported' : 'code_sent' })
        : reply(200, {})
    );
    const { onnotice, rerender } = mount();
    await fireEvent.input(screen.getByLabelText('Phone number'), { target: { value: '+34 612 345 678' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Send the code' }));
    await waitFor(() => expect(posts('/login/phone')).toHaveLength(1));
    await rerender({ login: { step: 'code', delivery: 'app' } });
    await fireEvent.click(await screen.findByRole('button', { name: 'Send a new code' }));
    await waitFor(() => expect(posts('/login/phone')).toHaveLength(2));
    expect(posts('/login/phone')[1].phone).toBe('+34 612 345 678');
    await waitFor(() => expect(onnotice.mock.calls.at(-1)[0]?.text).toMatch(/Use the code already sent/));
    expect(screen.getByLabelText('Login code')).toBeInTheDocument();
  });

  it('lets the owner use a different number', async () => {
    globalThis.fetch = vi.fn(() => reply(200, { outcome: 'expired' }));
    const { onnotice } = mount({ login: { step: 'code', delivery: 'app' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Use a different number' }));
    await fireEvent.input(screen.getByLabelText('Phone number'), { target: { value: '+1 555 000 1111' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Send the code' }));
    await waitFor(() => expect(onnotice.mock.calls.at(-1)[0]?.text).toMatch(/^This sign-in expired/));
    expect(posts('/login/phone')).toEqual([{ phone: '+1 555 000 1111', generation: 7 }]);
  });
});
