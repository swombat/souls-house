import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import WorkStatusSummary from './WorkStatusSummary.svelte';
import { WORK_STATUSES } from '$lib/work-status';

test.each(WORK_STATUSES)('labels $state without relying on colour', ({ state, label, colour }) => {
  const { container } = render(WorkStatusSummary, {
    status: { state, reason: 'Reported by the owner', since: '2026-11-11T20:00:00Z' },
  });
  const summary = screen.getByTestId('work-status-summary');
  expect(summary).toHaveAccessibleName(new RegExp(`${label} \\(reported\\)`));
  expect(summary).toHaveTextContent(label);
  expect(container.querySelector('svg')).toBeInTheDocument();
  expect(container.querySelector('[aria-hidden=true]').className).toContain(colour);
});

test('unknown does not become idle', () => {
  render(WorkStatusSummary, { status: { state: null } });
  expect(screen.queryByTestId('work-status-summary')).not.toBeInTheDocument();
});
