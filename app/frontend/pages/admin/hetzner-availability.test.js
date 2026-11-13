import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import HetznerAvailability from './hetzner-availability.svelte';
import { PAIR_SIZES, stepPath } from '$lib/hetzner-availability.js';

const now = '2026-11-13T01:00:00Z';
const points = [
  ['2026-11-13T00:00:00Z', 0],
  ['2026-11-13T00:05:00Z', 1],
  ['2026-11-13T00:10:00Z', null],
  ['2026-11-13T00:15:00Z', 1],
  ['2026-11-13T00:45:00Z', 0],
];
const series = Object.keys(PAIR_SIZES).map((label) => ({ label, points }));
const props = { now, series, checks: [{ at: now, types: {} }] };

test('renders four pairs on one shared binary chart without offsetting overlapping values', () => {
  render(HetznerAvailability, props);
  const chart = screen.getByRole('img', { name: 'Availability of all Hetzner pairs' });
  expect(screen.getAllByRole('img')).toHaveLength(1);
  const paths = chart.querySelectorAll('path[aria-label]');
  expect(paths).toHaveLength(4);
  const expected = stepPath(points, Date.parse(points[0][0]), Date.parse(now), 600, 160, { pad: 12 });
  expect(expected.match(/M/g)).toHaveLength(3);
  for (const path of paths) {
    expect(path).toHaveAttribute('d', expected);
    expect(path).toHaveAttribute('stroke-dasharray', '6 18');
    expect(path).toHaveAttribute('visibility', 'visible');
  }
  expect(new Set([...paths].map((path) => path.getAttribute('stroke'))).size).toBe(4);
  expect([...paths].map((path) => path.getAttribute('stroke-dashoffset'))).toEqual(['0', '-6', '-12', '-18']);
  expect(screen.getByText('Available')).toBeInTheDocument();
  expect(screen.getByText('Unavailable')).toBeInTheDocument();
});

test('shows size and known-check share beneath each pair and lets the legend isolate lines', async () => {
  render(HetznerAvailability, props);
  for (const line of series) {
    const button = screen.getByRole('button', { name: `Show ${line.label}` });
    expect(button).toHaveAttribute('aria-pressed', 'true');
    expect(within(button).getByText(PAIR_SIZES[line.label])).toBeInTheDocument();
    expect(within(button).getByText('50% of known checks available')).toBeInTheDocument();
  }
  const button = screen.getByRole('button', { name: `Show ${series[0].label}` });
  const chart = screen.getByRole('img', { name: 'Availability of all Hetzner pairs' });
  const paths = chart.querySelectorAll('path[aria-label]');
  await fireEvent.click(button);
  expect(button).toHaveAttribute('aria-pressed', 'false');
  expect(paths[0]).toHaveAttribute('visibility', 'hidden');
  expect(paths[1]).toHaveAttribute('visibility', 'visible');
  await fireEvent.click(button);
  expect(paths[0]).toHaveAttribute('visibility', 'visible');
});

test('keeps the no-checks message instead of an empty chart', () => {
  render(HetznerAvailability, { series });
  expect(screen.queryByRole('img')).not.toBeInTheDocument();
  expect(screen.getByText(/No checks yet/)).toBeInTheDocument();
});
