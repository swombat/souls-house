import { render, screen } from '@testing-library/svelte';
import { describe, it, expect } from 'vitest';
import StonesPanel from './StonesPanel.svelte';

function stones(percent = 0) {
  return {
    total: 2,
    weeks: ['2026-11-02', '2026-11-09'],
    created: [1, 2],
    namespace: { used: 2, retired: 1, reserved: 3, capacity: 16777216, percent },
  };
}

describe('StonesPanel', () => {
  it('shows global creation history, permanent reservations and the physical-deletion caveat', () => {
    render(StonesPanel, { stones: stones() });
    expect(screen.getByRole('heading', { name: 'Soul stones' })).toBeInTheDocument();
    expect(screen.getByRole('img', { name: 'Cumulative growth by week' })).toBeInTheDocument();
    const panel = screen.getByTestId('stones-dashboard');
    expect(panel.textContent).toContain('including founding and withdrawn');
    expect(panel.textContent).toContain('Physically deleted stones are not included');
    expect(panel.textContent).toContain('Retired · permanently held');
    expect(panel.textContent).toContain('16,777,216');
    expect(panel.textContent).toContain('Names are never reused');
  });

  it.each([
    [0, 'rgb(20, 184, 166)'],
    [49.9999, 'rgb(20, 184, 166)'],
    [50, 'rgb(249, 115, 22)'],
    [89.9999, 'rgb(249, 115, 22)'],
    [90, 'rgb(220, 38, 38)'],
    [100, 'rgb(220, 38, 38)'],
  ])('colors %s percent with the exact warning thresholds', (percent, color) => {
    render(StonesPanel, { stones: stones(percent) });
    const progress = screen.getByRole('progressbar', { name: 'Hostname namespace reserved' });
    expect(progress).toHaveAttribute('aria-valuenow', String(percent));
    expect(progress.firstElementChild.style.background).toBe(color);
    expect(progress.firstElementChild.style.width).toBe(`${percent}%`);
  });
});
