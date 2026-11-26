import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import AgentVisitsCard from './AgentVisitsCard.svelte';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

test('previews an invitation link, accepts it, and lists the new visit', async () => {
  const fetchMock = vi
    .fn()
    .mockResolvedValueOnce({ ok: true, json: async () => ({ visits: [] }) })
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        origin: 'https://nexus.example',
        token: 'vinv_12345678',
        preview: {
          account: { name: 'Nexus' },
          house: { name: 'Nexus House', origin: 'https://nexus.example' },
          local_name: null,
          expires_at: '2026-11-27T12:00:00Z',
          state: 'open',
        },
      }),
    })
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        visit: {
          id: 'vis1',
          visited_origin: 'https://nexus.example',
          visited_house_name: 'Nexus House',
          visited_account_name: 'Nexus',
          local_name: 'Reed (Grove)',
          status: 'active',
        },
      }),
    });

  vi.stubGlobal('fetch', fetchMock);
  render(AgentVisitsCard, { url: '/accounts/acc1/residents/ag1/visits', agentName: 'Reed' });

  const input = await screen.findByTestId('visit-invitation-input');
  await fireEvent.input(input, { target: { value: 'https://nexus.example/api/v1/visit/invitations/vinv_12345678' } });
  await fireEvent.click(screen.getByTestId('visit-preview-btn'));

  const panel = await screen.findByTestId('visit-preview-panel');
  expect(panel.textContent).toContain('Nexus');
  expect(panel.textContent).toContain('Nexus House');

  const nameInput = screen.getByTestId('visit-local-name-input');
  await fireEvent.input(nameInput, { target: { value: 'Reed (Grove)' } });
  await fireEvent.click(screen.getByTestId('visit-accept-btn'));

  const row = await screen.findByTestId('visit-row-vis1');
  expect(row.textContent).toContain('Nexus');
  expect(row.textContent).toContain('Reed (Grove)');
  expect(row.textContent).toContain('active');
});

test('leaves an active visit and updates its status', async () => {
  const fetchMock = vi
    .fn()
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        visits: [
          {
            id: 'vis1',
            visited_origin: 'https://nexus.example',
            visited_account_name: 'Nexus',
            local_name: 'Reed',
            status: 'active',
          },
        ],
      }),
    })
    .mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        visit: {
          id: 'vis1',
          visited_origin: 'https://nexus.example',
          visited_account_name: 'Nexus',
          local_name: 'Reed',
          status: 'ended',
        },
      }),
    });

  vi.stubGlobal('fetch', fetchMock);
  render(AgentVisitsCard, { url: '/accounts/acc1/residents/ag1/visits', agentName: 'Reed' });

  await fireEvent.click(await screen.findByTestId('visit-leave-vis1'));
  await waitFor(() => expect(screen.getByTestId('visit-row-vis1').textContent).toContain('ended'));
  expect(screen.queryByTestId('visit-leave-vis1')).toBeNull();
});
