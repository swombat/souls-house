import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import StoneCards from './StoneCards.svelte';

describe('stone cards', () => {
  it('pins the original revision and offers the newer one in a new tab', () => {
    render(StoneCards, {
      stones: [
        {
          id: 'revision',
          title: 'Options',
          number: 1,
          url: '/stones/stone/revisions/1',
          latest_url: '/stones/stone',
          newer_revision_available: true,
        },
      ],
    });
    expect(screen.getByRole('link', { name: 'Options' }).getAttribute('href')).toBe('/stones/stone/revisions/1');
    expect(screen.getByRole('link', { name: 'Options' }).getAttribute('target')).toBe('_blank');
    expect(screen.getByRole('link', { name: 'Newer revision available' }).getAttribute('href')).toBe('/stones/stone');
  });

  it('does not leave live links on withdrawn stones', () => {
    render(StoneCards, { stones: [{ id: 'revision', title: 'Private old title', withdrawn: true }] });
    expect(screen.getByText('Stone removed')).toBeTruthy();
    expect(screen.queryByRole('link')).toBeNull();
    expect(screen.queryByText('Private old title')).toBeNull();
  });
});
