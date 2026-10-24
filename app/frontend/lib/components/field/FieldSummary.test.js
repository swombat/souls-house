import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import FieldSummary from './FieldSummary.svelte';

const props = { text: 'An old summary.', url: '/accounts/a/field/recordings/r/resummarize' };

// The test window reports no fine pointer, so this is the phone path: tap the
// summary to show the button.
async function open() {
  render(FieldSummary, { props: { ...props, testid: 'summary' } });
  await fireEvent.click(screen.getByTestId('summary'));
}

describe('FieldSummary refresh', () => {
  beforeEach(() => router.post.mockReset());

  it('says so when a request finishes without being accepted', async () => {
    router.post.mockImplementation((url, data, options = {}) => options.onFinish?.());
    await open();
    await fireEvent.click(screen.getByTestId('summary-refresh'));
    expect(screen.getByTestId('summary-error').textContent).toContain("didn't go through");
    expect(screen.getByTestId('summary-refresh').disabled).toBe(false);
  });

  it('shows the server reason when refused', async () => {
    router.post.mockImplementation((url, data, options = {}) => {
      options.onError?.({ summary: 'A summary is already being written.' });
      options.onFinish?.();
    });
    await open();
    await fireEvent.click(screen.getByTestId('summary-refresh'));
    expect(screen.getByTestId('summary-error').textContent).toBe('A summary is already being written.');
  });

  it('shows no error once the request is accepted', async () => {
    router.post.mockImplementation((url, data, options = {}) => {
      options.onSuccess?.();
      options.onFinish?.();
    });
    await open();
    await fireEvent.click(screen.getByTestId('summary-refresh'));
    expect(screen.queryByTestId('summary-error')).toBeNull();
  });

  it('keeps the old text and permits manual refresh while stale', async () => {
    render(FieldSummary, { props: { ...props, freshness: 'stale' } });
    expect(screen.getByTestId('field-summary').textContent).toContain(props.text);
    expect(screen.getByTestId('summary-stale').textContent).toContain('out of date');
    expect(screen.getByTestId('summary-refresh').disabled).toBe(false);
    await fireEvent.click(screen.getByTestId('summary-refresh'));
    expect(router.post).toHaveBeenCalledWith(props.url, {}, expect.any(Object));
  });

  it('does not assert an untracked summary is current', () => {
    render(FieldSummary, { props: { ...props, freshness: 'unknown' } });
    expect(screen.getByTestId('summary-unknown').textContent).toContain("source wasn't tracked");
    expect(screen.getByTestId('summary-refresh').disabled).toBe(false);
  });

  it('only disables refresh while a new summary is actually pending', () => {
    render(FieldSummary, { props: { ...props, freshness: 'stale', pending: true } });
    expect(screen.getByTestId('summary-pending').textContent).toContain('Writing');
    expect(screen.getByTestId('summary-refresh').disabled).toBe(true);
  });

  it('removes the stale label when the refreshed result is current', async () => {
    const view = render(FieldSummary, { props: { ...props, freshness: 'stale' } });
    await view.rerender({ ...props, freshness: 'current', text: 'A new summary.' });
    expect(screen.queryByTestId('summary-stale')).toBeNull();
    expect(screen.getByTestId('field-summary').textContent).toContain('A new summary.');
  });
});
