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
});
