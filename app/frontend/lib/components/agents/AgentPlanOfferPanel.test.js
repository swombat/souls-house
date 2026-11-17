import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import AgentPlanOfferPanel from './AgentPlanOfferPanel.svelte';

const offer = (state, extra = {}) => ({
  available: state !== 'unavailable',
  owner_enabled: state !== 'unavailable',
  answer: null,
  answered_at: null,
  asked_at: null,
  active: false,
  state,
  ...extra,
});
const checkbox = () => screen.getByRole('checkbox', { name: 'Offer this resident a plan for long tasks' });
const status = () => screen.getByTestId('plan-offer-status');

describe('AgentPlanOfferPanel', () => {
  it('asked: says when, and that the offer is on until they answer', () => {
    render(AgentPlanOfferPanel, { enabled: true, planOffer: offer('asked', { asked_at: '2026-11-10T10:00:00Z' }) });
    expect(status()).toHaveTextContent(/^Asked on .*2026.*; no answer yet\. Until they answer, the offer is on\.$/);
    expect(checkbox()).not.toBeDisabled();
  });

  it('on: says they said yes', () => {
    render(AgentPlanOfferPanel, { enabled: true, planOffer: offer('on', { answered_at: '2026-11-11T10:00:00Z' }) });
    expect(status()).toHaveTextContent(/^They said yes on .*2026\. They can turn it off themselves\.$/);
  });

  it('declined: says their off holds over the owner on', () => {
    render(AgentPlanOfferPanel, { enabled: true, planOffer: offer('declined', { answered_at: '2026-11-12T10:00:00Z' }) });
    expect(status()).toHaveTextContent(
      /^They turned it off on .*2026\. Their off holds over your on; only they can turn it back on\.$/
    );
  });

  it('off: shows no status line', () => {
    render(AgentPlanOfferPanel, { enabled: false, planOffer: offer('off') });
    expect(screen.queryByTestId('plan-offer-status')).toBeNull();
    expect(checkbox()).not.toBeChecked();
  });

  it('unavailable: disables the checkbox and points to account settings', () => {
    render(AgentPlanOfferPanel, { enabled: false, planOffer: offer('unavailable') });
    expect(status()).toHaveTextContent('Switch on Plans for long tasks in the account settings first.');
    expect(checkbox()).toBeDisabled();
  });

  it('binds the checkbox', async () => {
    render(AgentPlanOfferPanel, { enabled: false, planOffer: offer('off') });
    await fireEvent.click(checkbox());
    expect(checkbox()).toBeChecked();
    await fireEvent.click(checkbox());
    expect(checkbox()).not.toBeChecked();
  });

  it('shows server errors', () => {
    render(AgentPlanOfferPanel, { enabled: false, planOffer: offer('off'), serverErrors: ['is not allowed'] });
    expect(screen.getByRole('alert')).toHaveTextContent('Plan offer is not allowed.');
  });
});
