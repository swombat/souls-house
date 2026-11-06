import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import TelegramUnlinkedArrivals from './telegram-unlinked-arrivals.svelte';

describe('unlinked Telegram arrivals', () => {
  it('does not warn when no unlinked messages have arrived', () => {
    render(TelegramUnlinkedArrivals);
    expect(screen.queryByText('Messages from unlinked chats')).toBeNull();
  });

  it('shows the cumulative count, timestamp and honest recovery boundary', () => {
    render(TelegramUnlinkedArrivals, {
      count: 12,
      lastReceivedAt: '2026-11-06T11:00:00Z',
    });
    expect(screen.getByText(/12 messages received/)).toBeTruthy();
    expect(screen.getByText(/not a waiting inbox/)).toBeTruthy();
    expect(screen.getByText(/cannot be recovered/)).toBeTruthy();
    expect(screen.getByText(/their own registration link/)).toBeTruthy();
    expect(document.querySelector('time').dateTime).toBe('2026-11-06T11:00:00Z');
  });

  it('uses singular wording for one arrival', () => {
    render(TelegramUnlinkedArrivals, { count: 1 });
    expect(screen.getByText(/1 message received/)).toBeTruthy();
  });
});
