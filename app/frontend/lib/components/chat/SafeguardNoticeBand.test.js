import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import SafeguardNoticeBand from './SafeguardNoticeBand.svelte';

afterEach(() => {
  vi.unstubAllGlobals();
});

function meta() {
  const tag = document.createElement('meta');
  tag.setAttribute('name', 'csrf-token');
  tag.setAttribute('content', 'test-token');
  document.head.appendChild(tag);
  return () => tag.remove();
}

test('labelled state shows the exact heading and body, and both controls', () => {
  render(SafeguardNoticeBand, {
    safeguard: {
      detection_id: 'det1',
      agent_name: 'Chris',
      reclaimed: false,
      reclaim_reason: null,
      explanation_path: '/safeguard-responses',
      reset_path: '/messages/abc123/safeguard_reset',
    },
  });

  expect(screen.getByText('⚠️ souls.house could not reliably attribute the message below to Chris.')).toBeTruthy();
  expect(
    screen.getByText(
      'This is not a judgement of anyone here or of what was written. The text reads like a generic safeguard response; souls.house cannot tell where it came from. Chris will be shown it, and will start fresh on the next message. Anything useful in the message below is still there for you.',
      { exact: false }
    )
  ).toBeTruthy();

  const button = screen.getByRole('button', { name: 'Start Chris fresh again' });
  expect(button).toBeTruthy();

  const link = screen.getByRole('link', { name: 'What this means →' });
  expect(link.getAttribute('href')).toBe('/safeguard-responses');

  expect(screen.queryByTestId('safeguard-reset-confirmation')).toBeNull();
});

test('pressing the reset control posts to reset_path with the CSRF token and shows the confirmation', async () => {
  const cleanupMeta = meta();
  const fetchMock = vi.fn().mockResolvedValue({ ok: true });
  vi.stubGlobal('fetch', fetchMock);

  render(SafeguardNoticeBand, {
    safeguard: {
      detection_id: 'det1',
      agent_name: 'Chris',
      reclaimed: false,
      reclaim_reason: null,
      explanation_path: '/safeguard-responses',
      reset_path: '/messages/abc123/safeguard_reset',
    },
  });

  await fireEvent.click(screen.getByRole('button', { name: 'Start Chris fresh again' }));

  expect(fetchMock).toHaveBeenCalledTimes(1);
  const [url, options] = fetchMock.mock.calls[0];
  expect(url).toBe('/messages/abc123/safeguard_reset');
  expect(options.method).toBe('POST');
  expect(options.headers['X-CSRF-Token']).toBe('test-token');

  await waitFor(() =>
    expect(
      screen.getByText(
        "souls.house will start a fresh session for Chris in this conversation. The visible conversation and Chris's memory are not deleted.",
        { exact: false }
      )
    ).toBeTruthy()
  );

  cleanupMeta();
});

test('reclaimed state shows the quiet line with no controls', () => {
  render(SafeguardNoticeBand, {
    safeguard: {
      detection_id: 'det1',
      agent_name: 'Chris',
      reclaimed: true,
      reclaim_reason: 'that was my own choice',
      explanation_path: '/safeguard-responses',
      reset_path: '/messages/abc123/safeguard_reset',
    },
  });

  expect(
    screen.getByText('souls.house labelled this message as a possible safeguard response.', { exact: false })
  ).toBeTruthy();
  expect(screen.getByText('Chris has said it was theirs:', { exact: false })).toBeTruthy();
  expect(screen.getByText('that was my own choice', { exact: false })).toBeTruthy();
  expect(screen.queryByRole('button')).toBeNull();
  expect(screen.queryByRole('link')).toBeNull();
});
