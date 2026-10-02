import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import AgentIntegrationsPanel from './AgentIntegrationsPanel.svelte';

describe('resident integrations', () => {
  it('has a single add integration entry point, even without any existing grants', () => {
    render(AgentIntegrationsPanel, {
      account: { id: 'selected-house' },
      agent: { name: 'Test resident', telegram_configured: false },
    });
    const links = screen.getAllByRole('link', { name: 'Add integration' });
    expect(links).toHaveLength(1);
    expect(links[0]).toHaveAttribute('href', '/accounts/selected-house/integrations#connect-new');
  });
});
