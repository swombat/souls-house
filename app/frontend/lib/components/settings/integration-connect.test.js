import { render, screen, fireEvent } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import { submitNativePost } from '$lib/integration-forms';
import IntegrationConnect from './integration-connect.svelte';

vi.mock('$lib/integration-forms', () => ({ submitNativePost: vi.fn() }));

const account = { id: 'selected-house' };
const dropbox = {
  key: 'dropbox',
  name: 'Dropbox',
  management_scopes: ['personal', 'account_managed'],
  connection_method: 'oauth2',
  authority_groups: [],
  access_profiles: [{ key: 'read_only', name: 'Read only', default: true }],
};
const github = {
  key: 'github',
  name: 'GitHub',
  management_scopes: ['personal'],
  connection_method: 'credentials',
  authority_groups: [],
  access_profiles: [],
  credential_fields: [
    { key: 'token', label: 'Token', type: 'password' },
    { key: 'repository', label: 'Repository' },
  ],
};

const twitterapi = {
  key: 'twitterapi_io',
  name: 'TwitterAPI.io',
  management_scopes: ['account_managed'],
  connection_method: 'credentials',
  authority_groups: [],
  access_profiles: [],
  credential_fields: [{ key: 'api_key', label: 'API key', type: 'password' }],
};

describe('integration scope and connection flow', () => {
  it('explains FreeAgent user authority without offering a fictitious read-only scope', async () => {
    const freeagent = {
      ...dropbox,
      key: 'freeagent',
      name: 'FreeAgent',
      access_profiles: [{ key: 'user_permissions', name: 'User permissions', default: true }],
    };
    render(IntegrationConnect, { account, focusedService: freeagent, canManageAccount: false });
    expect(screen.getByText(/FreeAgent has no read-only OAuth scope/)).toBeInTheDocument();
    expect(screen.getByText(/within that user's permission level/)).toBeInTheDocument();
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Connect FreeAgent' }));
    expect(submitNativePost).toHaveBeenCalledWith('/accounts/selected-house/service_authorizations', {
      provider: 'freeagent',
      management_scope: 'personal',
      access_profile: 'user_permissions',
    });
  });

  it('retains unsent credentials and ownership when read-only service props refresh', async () => {
    const props = { account, focusedService: github, canManageAccount: true };
    const view = render(IntegrationConnect, props);
    await fireEvent.input(screen.getByLabelText('Token'), { target: { value: 'synthetic-unsent-token' } });
    await fireEvent.input(screen.getByLabelText('Repository'), { target: { value: 'example/unfinished' } });
    await view.rerender({ ...props, focusedService: { ...github }, account: { ...account } });
    expect(screen.getByLabelText('Token')).toHaveValue('synthetic-unsent-token');
    expect(screen.getByLabelText('Repository')).toHaveValue('example/unfinished');
  });

  it('says an account-only key belongs to the account, and connects it as account-managed', async () => {
    render(IntegrationConnect, { account, focusedService: twitterapi, canManageAccount: true });
    expect(screen.getByText(/TwitterAPI.io is connected for the whole account/)).toBeInTheDocument();
    expect(screen.queryByText(/connected personally/)).not.toBeInTheDocument();
    expect(screen.queryByText(/will belong to you/)).not.toBeInTheDocument();
    await fireEvent.input(screen.getByLabelText('API key'), { target: { value: 'test-only-key' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Connect TwitterAPI.io' }));
    expect(router.post).toHaveBeenCalledWith('/accounts/selected-house/service_connections', {
      provider: 'twitterapi_io',
      management_scope: 'account_managed',
      credentials: { api_key: 'test-only-key' },
    });
  });

  it('lets admins choose account scope for a supported OAuth provider', async () => {
    render(IntegrationConnect, { account, focusedService: dropbox, canManageAccount: true });
    expect(screen.getByLabelText('Integration scope')).toBeInTheDocument();
    expect(screen.getByRole('radio', { name: /Just me/ })).toBeChecked();
    await fireEvent.click(screen.getByRole('radio', { name: /The whole account/ }));
    await fireEvent.click(screen.getByRole('button', { name: 'Connect Dropbox' }));
    expect(submitNativePost).toHaveBeenCalledWith('/accounts/selected-house/service_authorizations', {
      provider: 'dropbox',
      management_scope: 'account_managed',
      access_profile: 'read_only',
    });
  });

  it('connects personal OAuth for ordinary members without a scope selector', async () => {
    render(IntegrationConnect, { account, focusedService: dropbox, canManageAccount: false });
    expect(screen.queryByLabelText('Integration scope')).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Connect Dropbox' }));
    expect(submitNativePost).toHaveBeenCalledWith('/accounts/selected-house/service_authorizations', {
      provider: 'dropbox',
      management_scope: 'personal',
      access_profile: 'read_only',
    });
  });

  it('preserves personal-only credential providers even for admins', async () => {
    render(IntegrationConnect, { account, focusedService: github, canManageAccount: true });
    expect(screen.queryByLabelText('Integration scope')).not.toBeInTheDocument();
    expect(screen.getByText(/GitHub can only be connected personally/)).toBeInTheDocument();
    await fireEvent.input(screen.getByLabelText('Token'), { target: { value: 'test-only-token' } });
    await fireEvent.input(screen.getByLabelText('Repository'), { target: { value: 'owner/repo' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Connect GitHub' }));
    expect(router.post).toHaveBeenCalledWith('/accounts/selected-house/service_connections', {
      provider: 'github',
      management_scope: 'personal',
      credentials: { token: 'test-only-token', repository: 'owner/repo' },
    });
    expect(screen.getByRole('link', { name: 'Cancel' })).toHaveAttribute(
      'href',
      '/accounts/selected-house/integrations'
    );
  });
});
