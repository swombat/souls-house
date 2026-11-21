import { render, screen, cleanup, fireEvent } from '@testing-library/svelte';
import { afterEach, describe, expect, it } from 'vitest';
import Integrations from './integrations.svelte';

afterEach(cleanup);

describe('device integrations entry point', () => {
  it('links to the selected account with a native navigation, including for ordinary members', () => {
    render(Integrations, { account: { id: 'selected-house', name: 'Selected house' }, can_manage_account: false });
    const link = screen.getByRole('link', { name: /Polar H10 \/ RR stream/ });
    expect(link).toHaveAttribute('href', '/accounts/selected-house/device_streams');
    expect(screen.getByText(/Publish your own device readings/)).toBeInTheDocument();
  });

  it('links to X posting for the selected account', () => {
    render(Integrations, { account: { id: 'selected-house', name: 'Selected house' }, can_manage_account: false });
    expect(screen.getByRole('link', { name: /X posting/ })).toHaveAttribute(
      'href',
      '/x_integration?account_id=selected-house'
    );
  });

  it('clearly separates connecting new integrations from existing ones', () => {
    render(Integrations, {
      account: { id: 'selected-house', name: 'Selected house' },
      services: [{ key: 'github', name: 'GitHub' }],
    });
    expect(screen.getByRole('heading', { name: 'Connect a new integration' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Your integrations' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /^GitHub/ })).toHaveAttribute(
      'href',
      '/accounts/selected-house/integrations?connect=github'
    );
  });
});

describe('connect a new integration list', () => {
  const services = [
    { key: 'xero', name: 'Xero' },
    { key: 'dropbox', name: 'Dropbox' },
    { key: 'google_workspace', name: 'Google Workspace' },
    { key: 'github', name: 'GitHub repository' },
  ];
  const connectNames = () =>
    screen
      .getAllByRole('link')
      .filter((link) => link.closest('#connect-new'))
      .map((link) => link.querySelector('.font-medium').textContent.trim());

  it('lists every integration, including Polar and X, alphabetically', () => {
    render(Integrations, { account: { id: 'h' }, services });
    expect(connectNames()).toEqual([
      'Dropbox',
      'GitHub repository',
      'Google Workspace',
      'Polar H10 / RR stream',
      'X posting',
      'Xero',
    ]);
  });

  it('narrows the list as you type, matching name or description', async () => {
    render(Integrations, { account: { id: 'h' }, services });
    const box = screen.getByRole('searchbox', { name: 'Filter integrations' });
    await fireEvent.input(box, { target: { value: 'goo' } });
    expect(connectNames()).toEqual(['Google Workspace']);
    await fireEvent.input(box, { target: { value: 'invoices' } });
    expect(connectNames()).toEqual(['Xero']);
    await fireEvent.input(box, { target: { value: 'zzz' } });
    expect(connectNames()).toEqual([]);
    expect(screen.getByText(/No integration matches/)).toBeInTheDocument();
  });
});

describe('the X posting row', () => {
  const xPosting = {
    connected: true,
    enabled: true,
    x_username: 'househandle',
    media_scope_granted: true,
    can_manage: true,
    page_url: '/x_integration?account_id=h',
    grant_url: '/x_integration/grant?account_id=h',
    residents: [
      { id: 'lume', name: 'Lume', active: true, enabled: true },
      { id: 'mira', name: 'Mira', active: true, enabled: false },
    ],
  };

  it('appears under Your integrations with who can post, and switches per resident when opened', async () => {
    render(Integrations, { account: { id: 'h' }, x_posting: xPosting });
    expect(screen.queryByText('Nothing connected yet')).not.toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '@househandle' })).toBeInTheDocument();
    expect(screen.getByTestId('x-posting-summary')).toHaveTextContent('Lume can post');

    await fireEvent.click(screen.getByRole('button', { name: /@househandle/ }));
    expect(screen.getByLabelText('Lume')).toBeChecked();
    expect(screen.getByLabelText('Mira')).not.toBeChecked();
    expect(screen.getByRole('link', { name: /account-wide switch are on the X page/ })).toHaveAttribute(
      'href',
      '/x_integration?account_id=h'
    );
  });

  it('starts open and says so when X needs reconnecting for media', () => {
    render(Integrations, { account: { id: 'h' }, x_posting: { ...xPosting, media_scope_granted: false } });
    expect(screen.getByTestId('x-posting-attention')).toHaveTextContent('Reconnect X to post media');
    expect(screen.getByLabelText('Lume')).toBeInTheDocument();
  });

  it('lets members see but not change the switches', () => {
    render(Integrations, {
      account: { id: 'h' },
      x_posting: { ...xPosting, can_manage: false, media_scope_granted: false },
    });
    expect(screen.getByLabelText('Lume')).toBeDisabled();
    expect(screen.getByText('Account admins change who can post.')).toBeInTheDocument();
  });

  it('is absent until the account starts on X', () => {
    render(Integrations, { account: { id: 'h' } });
    expect(screen.queryByTestId('x-posting-connection')).not.toBeInTheDocument();
  });
});
