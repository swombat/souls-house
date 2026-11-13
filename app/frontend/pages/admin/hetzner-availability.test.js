import { render, screen } from '@testing-library/svelte';
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

test('keeps four separate binary charts with gaps', () => {
  render(HetznerAvailability, props);
  expect(screen.getAllByRole('img')).toHaveLength(4);
  const expected = stepPath(points, Date.parse(points[0][0]), Date.parse(now), 600, 28);
  expect(expected.match(/M/g)).toHaveLength(3);
  const colors = [];
  for (const line of series) {
    const chart = screen.getByRole('img', { name: `${line.label} availability` });
    const path = chart.querySelector('path');
    expect(path).toHaveAttribute('d', expected);
    expect(path).not.toHaveAttribute('stroke-dasharray');
    colors.push(path.getAttribute('stroke'));
  }
  expect(new Set(colors).size).toBe(4);
});

test('shows the confirmed machine sizes beneath the pair labels', () => {
  render(HetznerAvailability, props);
  const sizes = [
    '2 vCPU / 4 GB RAM / 40 GB NVMe',
    '4 vCPU / 8 GB RAM / 80 GB NVMe',
    '8 vCPU / 16 GB RAM / 160 GB NVMe',
    '16 vCPU / 32 GB RAM / 320 GB NVMe',
  ];
  for (const [index, line] of series.entries()) {
    const label = screen.getByText(line.label, { exact: true });
    expect(label.nextElementSibling).toHaveTextContent(sizes[index]);
  }
  expect(screen.getAllByTitle('Share of checks available')).toHaveLength(4);
  expect(screen.getAllByText('50%')).toHaveLength(4);
});

test('keeps the no-checks message instead of an empty chart', () => {
  render(HetznerAvailability, { series });
  expect(screen.queryByRole('img')).not.toBeInTheDocument();
  expect(screen.getByText(/No checks yet/)).toBeInTheDocument();
});
