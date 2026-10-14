import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import TelegramSignIn from './telegram_sign_in.svelte';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const account = { id: 'house', name: 'House' };

describe('the focused Telegram sign-in page', () => {
  it('shows the sign-in itself, and that it is on Integrations too', async () => {
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ status: 'pairing', qr: null, login: {} }),
      })
    );
    render(TelegramSignIn, {
      account,
      connection: { id: 'svc_9', provider: 'telegram', status: 'pairing' },
      integrations_url: '/accounts/house/integrations',
    });
    expect(screen.getByRole('heading', { name: 'Sign in to Telegram' })).toBeInTheDocument();
    expect(screen.getByTestId('telegram-login')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Integrations page' })).toHaveAttribute(
      'href',
      '/accounts/house/integrations'
    );
    expect(globalThis.fetch).toHaveBeenCalledWith(
      '/accounts/house/service_connections/svc_9/pairing',
      expect.anything()
    );
  });

  it('ends with Connected and a way back to Integrations', () => {
    globalThis.fetch = vi.fn();
    render(TelegramSignIn, {
      account,
      connection: { id: 'svc_9', provider: 'telegram', status: 'connected', identity: 'Daniel (@daniel)' },
      integrations_url: '/accounts/house/integrations',
    });
    expect(screen.getByTestId('telegram-sign-in-done')).toHaveTextContent('Connected as Daniel (@daniel).');
    expect(screen.getByRole('link', { name: 'Back to Integrations' })).toHaveAttribute(
      'href',
      '/accounts/house/integrations'
    );
    expect(screen.queryByTestId('telegram-login')).not.toBeInTheDocument();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });
});
