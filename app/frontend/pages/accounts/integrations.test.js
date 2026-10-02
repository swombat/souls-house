import { render, screen, cleanup } from '@testing-library/svelte';
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
