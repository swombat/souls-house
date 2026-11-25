import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it } from 'vitest';
import Show from './show.svelte';
import { accountApiKeysPath } from '@/routes';

afterEach(cleanup);

describe('API key completion destination', () => {
  const props = { account: { id: 1 }, api_key: { name: 'Example body' }, raw_token: '' };

  it('returns resident flows to Settings', () => {
    render(Show, { ...props, return_url: '/residents/42/edit?tab=settings#connect-another-body' });
    expect(screen.getByRole('link', { name: 'Done' }).getAttribute('href')).toBe(
      '/residents/42/edit?tab=settings#connect-another-body'
    );
  });

  it('keeps the personal key flow unchanged', () => {
    render(Show, props);
    expect(screen.getByRole('link', { name: 'Done' }).getAttribute('href')).toBe(accountApiKeysPath(1));
  });
});
