import { render, screen, cleanup } from '@testing-library/svelte';
import { afterEach, describe, expect, it } from 'vitest';
import Services from './services.svelte';

afterEach(cleanup);

describe('device integrations entry point', () => {
  it('links to the selected account with a native navigation, including for ordinary members', () => {
    render(Services, { account: { id: 'selected-house', name: 'Selected house' }, can_manage: false });
    const link = screen.getByRole('link', { name: 'Manage your device streams' });
    expect(link).toHaveAttribute('href', '/accounts/selected-house/device_streams');
    expect(screen.getByRole('heading', { name: 'Device integrations' })).toBeInTheDocument();
    expect(screen.getByText(/Publish your own device readings to Selected house/)).toBeInTheDocument();
  });
});
