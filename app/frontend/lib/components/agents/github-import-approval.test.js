import { render, fireEvent, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import Approval from './github-import-approval.svelte';

const request = {
  id: 'request',
  review_revision: 'review-one',
  status: 'pending_review',
  commit_sha: 'sha-one',
  credential_fingerprint: 'fingerprint-one',
  current_credential_fingerprint: 'fingerprint-one',
  token_metadata: { token_kind: 'fine_grained' },
};

test('a refreshed commit or changed credential clears an unsubmitted confirmation', async () => {
  const props = { request, approveUrl: '/approve', canApprove: true };
  const { rerender } = render(Approval, props);
  await fireEvent.click(screen.getByRole('checkbox'));
  expect(screen.getByRole('checkbox')).toBeChecked();
  await rerender({ ...props, request: { ...request, commit_sha: 'sha-two' } });
  expect(screen.getByRole('checkbox')).not.toBeChecked();
  await fireEvent.click(screen.getByRole('checkbox'));
  await rerender({
    ...props,
    request: { ...request, commit_sha: 'sha-two', current_credential_fingerprint: 'fingerprint-two' },
  });
  expect(screen.getByRole('checkbox')).not.toBeChecked();
});

test('a concurrent review revision change clears confirmation even with the same SHA and fingerprint', async () => {
  const props = { request, approveUrl: '/approve', canApprove: true };
  const { rerender } = render(Approval, props);
  await fireEvent.click(screen.getByRole('checkbox'));
  await rerender({ ...props, request: { ...request, review_revision: 'review-two' } });
  expect(screen.getByRole('checkbox')).not.toBeChecked();
  expect(screen.getByRole('button', { name: 'Approve repository execution' })).toBeDisabled();
});

test('credential rotation refreshes the same request before explicit reapproval', async () => {
  const props = {
    request: { ...request, status: 'ready', credential_changed: true, approval_valid: false },
    approveUrl: '/same-request/approve',
    refreshUrl: '/same-request/refresh',
    canApprove: true,
  };
  const { rerender } = render(Approval, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Refresh review' }));
  expect(router.post).toHaveBeenCalledWith('/same-request/refresh', {}, expect.any(Object));
  router.post.mock.calls.at(-1)[2].onFinish();
  await rerender({
    ...props,
    request: {
      ...request,
      credential_changed: false,
      credential_fingerprint: 'rotated',
      current_credential_fingerprint: 'rotated',
    },
  });
  const approval = screen.getByRole('button', { name: 'Approve repository execution' });
  expect(approval).toBeDisabled();
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.click(approval);
  expect(router.post).toHaveBeenLastCalledWith(
    '/same-request/approve',
    { confirmed: 'true', review_revision: 'review-one' },
    expect.any(Object)
  );
});
