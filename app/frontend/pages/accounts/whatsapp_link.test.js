import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import WhatsappLink from './whatsapp_link.svelte';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const account = { id: 'house', name: 'House' };

describe('the focused WhatsApp pairing page', () => {
  it('shows the pairing itself, fetched from the pairing endpoint, and that it is on Integrations too', async () => {
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ status: 'pairing', qr: null, attempt: 1, phone: {}, phone_code: null }),
      })
    );
    render(WhatsappLink, {
      account,
      connection: { id: 'svc_9', provider: 'whatsapp', status: 'pairing' },
      integrations_url: '/accounts/house/integrations',
    });
    expect(screen.getByRole('heading', { name: 'Link WhatsApp' })).toBeInTheDocument();
    expect(screen.getByTestId('whatsapp-pairing')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Integrations page' })).toHaveAttribute(
      'href',
      '/accounts/house/integrations'
    );
    expect(globalThis.fetch).toHaveBeenCalledWith(
      '/accounts/house/service_connections/svc_9/pairing',
      expect.anything()
    );
  });

  it('ends with Linked and a way back to Integrations', () => {
    globalThis.fetch = vi.fn();
    render(WhatsappLink, {
      account,
      connection: { id: 'svc_9', provider: 'whatsapp', status: 'connected', identity: '+34 600 000 000' },
      integrations_url: '/accounts/house/integrations',
    });
    expect(screen.getByTestId('whatsapp-link-done')).toHaveTextContent('Linked as +34 600 000 000.');
    expect(screen.getByRole('link', { name: 'Back to Integrations' })).toHaveAttribute(
      'href',
      '/accounts/house/integrations'
    );
    expect(screen.queryByTestId('whatsapp-pairing')).not.toBeInTheDocument();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });
});
