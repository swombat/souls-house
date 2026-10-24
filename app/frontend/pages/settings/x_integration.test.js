import { render, screen, cleanup, fireEvent } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

const { put } = vi.hoisted(() => ({ put: vi.fn() }));
vi.mock('@inertiajs/svelte', () => ({ router: { put, patch: vi.fn(), delete: vi.fn() } }));

import XIntegration from './x_integration.svelte';

afterEach(() => {
  cleanup();
  put.mockReset();
});

const base = {
  id: 1,
  enabled: false,
  connected: false,
  x_username: null,
  app_source: null,
  house_app_allowed: false,
  own_app: false,
  own_client_id: null,
  callback_url: 'https://house.example.test/x_integration/callback',
  outcome_unknown_count: 0,
};

describe('X posting page', () => {
  it('asks an account without an X app for its own, and offers no Connect button yet', async () => {
    render(XIntegration, { account_id: 'acct', integration: base, can_manage: true });

    expect(screen.getByText(/this account needs its own X app/)).toBeInTheDocument();
    expect(screen.getByText('https://house.example.test/x_integration/callback')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Connect with X/ })).not.toBeInTheDocument();
    expect(screen.queryByText(/posts in any 24 hours/)).not.toBeInTheDocument();

    await fireEvent.input(screen.getByLabelText('Client ID'), { target: { value: 'cid' } });
    await fireEvent.input(screen.getByLabelText('Client secret'), { target: { value: 'secret' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Save X app' }));

    expect(put).toHaveBeenCalledWith(
      '/x_integration/app?account_id=acct',
      { x_app: { client_id: 'cid', client_secret: 'secret' } },
      expect.any(Object)
    );
  });

  it('lets an account with its own app connect, and shows only the client id', () => {
    render(XIntegration, {
      account_id: 'acct',
      integration: { ...base, app_source: 'own', own_app: true, own_client_id: 'cid-123' },
      can_manage: true,
    });

    expect(screen.getByText('cid-123')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Connect with X/ })).toBeInTheDocument();
    expect(screen.queryByLabelText('Client secret')).not.toBeInTheDocument();
  });

  it('says when the house app is in use and does not ask for an app', () => {
    render(XIntegration, {
      account_id: 'acct',
      integration: { ...base, app_source: 'house', house_app_allowed: true },
      can_manage: true,
    });

    expect(screen.getByText(/posts through the house X app/)).toBeInTheDocument();
    expect(screen.queryByLabelText('Client ID')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Connect with X/ })).toBeInTheDocument();
  });

  it('lets an admin of a house-app account switch to its own app', async () => {
    render(XIntegration, {
      account_id: 'acct',
      integration: { ...base, app_source: 'house', house_app_allowed: true },
      can_manage: true,
    });

    await fireEvent.click(screen.getByRole('button', { name: /own X app instead/ }));

    expect(screen.getByLabelText('Client ID')).toBeInTheDocument();
    expect(screen.getByLabelText('Client secret')).toBeInTheDocument();
  });

  it('shows ordinary members no X app form', () => {
    render(XIntegration, { account_id: 'acct', integration: base, can_manage: false });

    expect(screen.queryByLabelText('Client ID')).not.toBeInTheDocument();
  });
});
