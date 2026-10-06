import { render, screen, fireEvent } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import GithubImportStatus from './github-import-status.svelte';

const request = { status: 'needs_runtime_trust', approval_valid: true, repository: 'example-org/example-home' };

test('a seeded home needing runtime trust is not presented as ready', () => {
  render(GithubImportStatus, { request, runtimeTrustNotice: 'An operator must grant trust in Chaos.' });
  expect(screen.getByRole('heading')).toHaveTextContent('operator trust step needed');
  expect(screen.getByText(/resident is not online/)).toBeVisible();
  expect(screen.getByText('An operator must grant trust in Chaos.')).toBeVisible();
  expect(screen.queryByRole('button')).not.toBeInTheDocument();
});

test('an account-authorized activation retry requires valid approval and reports rejection', async () => {
  router.post.mockImplementationOnce((_url, _data, options) => {
    options.onError({});
    options.onFinish();
  });
  render(GithubImportStatus, { request, retryActivationUrl: '/retry-activation' });
  await fireEvent.click(screen.getByRole('button', { name: 'Retry activation after operator trust' }));
  expect(router.post).toHaveBeenCalledWith('/retry-activation', {}, expect.any(Object));
  expect(screen.getByRole('alert')).toHaveTextContent('Activation was not accepted');
});

test('invalidated approval cannot retry activation', () => {
  render(GithubImportStatus, { request: { ...request, approval_valid: false }, retryActivationUrl: '/retry' });
  expect(screen.getByRole('button')).toBeDisabled();
});
