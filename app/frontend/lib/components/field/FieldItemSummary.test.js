import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import FieldItemCard from './FieldItemCard.svelte';
import FieldItemRow from './FieldItemRow.svelte';

const item = {
  key: 'file-a',
  kind: 'file',
  title: 'Orchard plan',
  summary_short: 'Planting next spring',
  created_at: '2026-10-13T08:00:00Z',
};

describe.each([
  ['card', FieldItemCard],
  ['row', FieldItemRow],
])('Field summary in a %s', (name, component) => {
  it('keeps untracked archive summaries quiet in the list', () => {
    render(component, { props: { item: { ...item, summary_freshness: 'unknown' }, onSelect: () => {} } });
    expect(screen.queryByTestId('field-item-summary-freshness')).toBeNull();
    expect(screen.getByTestId('field-item').textContent).toContain(item.summary_short);
  });

  it('still flags a known stale summary', () => {
    render(component, { props: { item: { ...item, summary_freshness: 'stale' }, onSelect: () => {} } });
    expect(screen.getByTestId('field-item-summary-freshness').textContent).toContain('Summary out of date');
  });
});
