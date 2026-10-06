import { render, fireEvent, screen } from '@testing-library/svelte';
import { get } from 'svelte/store';
import { router, useForm } from '@inertiajs/svelte';
import GithubImport from './github-import.svelte';

const authority = {
  token_kind: 'fine_grained',
  oauth_scopes: [],
  authority_source: 'Token format',
  authority_summary: 'Repository selection must be reviewed in GitHub.',
  warnings: ['Permissions cannot be inferred from successful connectivity.'],
};
const props = {
  account: { id: 'account' },
  connections: [{ id: 'connection', label: 'Identity home', repository: 'example/home', token_metadata: authority }],
  models: [{ model_id: 'openai/test-model', label: 'Test model' }],
  submit_url: '/imports',
  future_branch_trust_notice: 'Future branch pushes are trusted without another commit approval.',
};
const request = {
  id: 'request',
  review_revision: 'review-one',
  status: 'pending_review',
  name: 'Existing Resident',
  model_id: 'openai/test-model',
  repository: 'example/home',
  branch: 'main',
  commit_sha: 'current-sha',
  credential_fingerprint: 'current-fingerprint',
  current_credential_fingerprint: 'live-fingerprint',
  approved_commit_sha: null,
  approved_credential_fingerprint: null,
  portable_home_id: 'existing-identity',
  home_profile: 'portable_v1',
  token_metadata: authority,
  approval_valid: false,
};

test('prepares a request without a soul seed or automatic execution', async () => {
  render(GithubImport, props);
  expect(screen.getByText(/local harness remains separate/)).toBeVisible();
  expect(screen.getByText(/format is not proof of least privilege/)).toBeVisible();
  expect(screen.getByText(authority.warnings[0])).toBeVisible();
  expect(screen.getByRole('link', { name: 'Manifest and local harness guide' })).toHaveAttribute(
    'href',
    'https://github.com/swombat/souls-house/blob/master/docs/features/github-resident-onboarding.md'
  );
  expect(screen.queryByRole('textbox', { name: /soul/i })).not.toBeInTheDocument();
  const submit = screen.getByRole('button', { name: 'Request site-admin review' });
  expect(submit).toBeDisabled();
  await fireEvent.input(screen.getByLabelText('Resident display name'), { target: { value: 'Existing Resident' } });
  await fireEvent.click(submit);
  const form = useForm.mock.results.at(-1).value;
  expect(form.post).toBeUndefined();
  expect(get(form).post).toHaveBeenCalledWith('/imports');
  expect(useForm.mock.calls.at(-1)[0]).toEqual({
    github_resident_import: {
      name: 'Existing Resident',
      model_id: 'openai/test-model',
      service_connection_id: 'connection',
      branch: '',
      sync_strategy: 'existing',
    },
  });
  expect(router.post).not.toHaveBeenCalled();
});

test('standard sync is an explicit choice with manifest-owned paths, not a paths editor', async () => {
  render(GithubImport, props);
  expect(screen.getByRole('radio', { name: 'Keep existing sync' })).toBeChecked();
  await fireEvent.click(screen.getByRole('radio', { name: 'Use standard two-way Git sync' }));
  expect(screen.getByText(/uncommitted edits are not automatically saved/)).toBeVisible();
  expect(screen.getByText(/not a promise of automatic conflict resolution/)).toBeVisible();
  expect(screen.queryByRole('textbox', { name: /paths/i })).not.toBeInTheDocument();
  await fireEvent.input(screen.getByLabelText('Resident display name'), { target: { value: 'Example' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Request site-admin review' }));
  const form = get(useForm.mock.results.at(-1).value);
  expect(form.github_resident_import.sync_strategy).toBe('standard');
  expect(form.github_resident_import).not.toHaveProperty('sync_auto_commit_paths');
});

test.each(['classic', 'unknown', 'unexpected_kind'])(
  'blocks %s credentials even when a connection exists',
  async (kind) => {
    render(GithubImport, {
      ...props,
      connections: [
        {
          ...props.connections[0],
          token_metadata: { ...authority, token_kind: kind, oauth_scopes: ['repo', 'workflow'] },
        },
      ],
    });
    expect(screen.getByText('repo, workflow')).toBeVisible();
    expect(screen.getByRole('alert')).toHaveTextContent('Classic and unknown tokens cannot');
    await fireEvent.input(screen.getByLabelText('Resident display name'), { target: { value: 'Existing Resident' } });
    expect(screen.getByRole('button', { name: 'Request site-admin review' })).toBeDisabled();
  }
);

test('switching to a blocked connection updates authority and disables submission', async () => {
  render(GithubImport, {
    ...props,
    connections: [
      ...props.connections,
      {
        id: 'classic',
        label: 'Broad token',
        repository: 'example/other',
        token_metadata: { token_kind: 'classic', oauth_scopes: ['repo'] },
      },
    ],
  });
  await fireEvent.input(screen.getByLabelText('Resident display name'), { target: { value: 'Existing Resident' } });
  expect(screen.getByRole('button', { name: 'Request site-admin review' })).toBeEnabled();
  await fireEvent.change(screen.getByLabelText('GitHub connection'), { target: { value: 'classic' } });
  expect(screen.getByRole('button', { name: 'Request site-admin review' })).toBeDisabled();
  expect(screen.getByText('Classic token')).toBeVisible();
});

test('empty connections provide an account-scoped setup link, not an import form', () => {
  render(GithubImport, { ...props, connections: [] });
  expect(screen.getByRole('link', { name: 'Open personal services' })).toHaveAttribute(
    'href',
    '/accounts/account/personal_services'
  );
  expect(screen.queryByRole('button', { name: 'Request site-admin review' })).not.toBeInTheDocument();
});

test('server form errors remain visible without losing the request form', async () => {
  render(GithubImport, props);
  const form = useForm.mock.results.at(-1).value;
  form.update((value) => ({
    ...value,
    errors: { name: ['Name is already in use'], base: ['Repository cannot be reviewed'] },
  }));
  expect(await screen.findByText('Name is already in use')).toBeVisible();
  expect(screen.getByText('Repository cannot be reviewed')).toBeVisible();
  expect(screen.getByLabelText('Resident display name')).toBeVisible();
});

test('real-shaped processing state disables duplicate request submission', async () => {
  render(GithubImport, props);
  await fireEvent.input(screen.getByLabelText('Resident display name'), { target: { value: 'Existing Resident' } });
  const form = useForm.mock.results.at(-1).value;
  form.update((value) => ({ ...value, processing: true }));
  expect(await screen.findByRole('button', { name: 'Submitting…' })).toBeDisabled();
  expect(screen.getByLabelText('GitHub connection')).toBeDisabled();
  expect(get(form).post).not.toHaveBeenCalled();
});

test('ordinary users can see SHA and fingerprint review data without admin actions', () => {
  render(GithubImport, { ...props, github_import: { ...request, credential_changed: true } });
  expect(screen.getByText('Waiting for site-admin review')).toBeVisible();
  expect(screen.getByText('current-sha')).toBeVisible();
  expect(screen.getByText('current-fingerprint')).toBeVisible();
  expect(screen.getByText('live-fingerprint')).toBeVisible();
  expect(screen.getByText(props.future_branch_trust_notice)).toBeVisible();
  expect(screen.getByText(/changed credential requires site-admin reapproval/)).toBeVisible();
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Approve repository execution' })).not.toBeInTheDocument();
  expect(screen.queryByText('Beginning recorded')).not.toBeInTheDocument();
});

test('site approval requires explicit future-branch trust confirmation and submits once', async () => {
  render(GithubImport, { ...props, github_import: request, can_approve: true, approve_url: '/approve' });
  const approval = screen.getByRole('button', { name: 'Approve repository execution' });
  expect(approval).toBeDisabled();
  expect(screen.getByRole('checkbox')).toHaveAccessibleName(/including future pushes, with broad runtime privileges/);
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.click(approval);
  expect(router.post).toHaveBeenCalledWith(
    '/approve',
    { confirmed: 'true', review_revision: 'review-one' },
    expect.objectContaining({ preserveScroll: true })
  );
  expect(approval).toBeDisabled();
  expect(router.post).toHaveBeenCalledTimes(1);
  expect(screen.queryByText('Approval is valid for this credential and future branch pushes.')).not.toBeInTheDocument();
});

test('a rejected stale approval displays the server error and requires a new confirmation', async () => {
  render(GithubImport, { ...props, github_import: request, can_approve: true, approve_url: '/approve' });
  await fireEvent.click(screen.getByRole('checkbox'));
  await fireEvent.click(screen.getByRole('button', { name: 'Approve repository execution' }));
  const options = router.post.mock.calls.at(-1)[2];
  options.onError({ base: ['Credential changed; refresh review before approval.'] });
  options.onFinish();
  expect(await screen.findByText(/Approval was rejected.*Credential changed/)).toBeVisible();
  expect(screen.getByRole('checkbox')).not.toBeChecked();
  expect(screen.getByRole('button', { name: 'Approve repository execution' })).toBeDisabled();
  expect(screen.queryByText('Approval is valid for this credential and future branch pushes.')).not.toBeInTheDocument();
});

test('ready with an invalid credential offers data-only refresh review, not direct approval', async () => {
  render(GithubImport, {
    ...props,
    github_import: { ...request, status: 'ready', credential_changed: true },
    can_approve: true,
    approve_url: '/approve',
    refresh_url: '/refresh',
  });
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  expect(screen.getByText(/Their existing home is preserved/)).toBeVisible();
  await fireEvent.click(screen.getByRole('button', { name: 'Refresh review' }));
  expect(router.post).toHaveBeenCalledWith('/refresh', {}, expect.objectContaining({ preserveScroll: true }));
  expect(screen.getByRole('button', { name: 'Refreshing…' })).toBeDisabled();
  expect(screen.queryByText('Approval is valid for this credential and future branch pushes.')).not.toBeInTheDocument();
});

test('pending review with a changed credential requires refresh before approval', () => {
  render(GithubImport, {
    ...props,
    github_import: { ...request, credential_changed: true },
    can_approve: true,
    approve_url: '/approve',
    refresh_url: '/refresh',
  });
  expect(screen.getByRole('button', { name: 'Refresh review' })).toBeEnabled();
  expect(screen.getByRole('checkbox')).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Approve repository execution' })).toBeDisabled();
});

test('a refresh error is visible and does not strand credential rotation', async () => {
  render(GithubImport, {
    ...props,
    github_import: { ...request, status: 'failed', credential_changed: true },
    refresh_url: '/refresh',
  });
  await fireEvent.click(screen.getByRole('button', { name: 'Refresh review' }));
  const options = router.post.mock.calls.at(-1)[2];
  options.onError({ base: ['Not authorized to refresh this request.'] });
  options.onFinish();
  expect(await screen.findByText(/Review refresh failed.*Not authorized/)).toBeVisible();
  expect(screen.getByRole('button', { name: 'Refresh review' })).toBeEnabled();
});

test('current token metadata is distinct and blocks approval after rotation to classic credentials', () => {
  render(GithubImport, {
    ...props,
    github_import: {
      ...request,
      status: 'failed',
      credential_changed: true,
      current_token_metadata: { token_kind: 'classic', oauth_scopes: ['repo'], authority_source: 'GitHub scopes' },
    },
    can_approve: true,
    approve_url: '/approve',
    refresh_url: '/refresh',
  });
  expect(screen.getByRole('region', { name: 'Reviewed token authority' })).toHaveTextContent('Fine-grained');
  expect(screen.getByRole('region', { name: 'Current token authority' })).toHaveTextContent('Classic token');
  expect(screen.getByRole('checkbox')).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Refresh review' })).toBeEnabled();
});

test('unchanged authority and unapproved provenance do not duplicate the review', () => {
  render(GithubImport, {
    ...props,
    github_import: { ...request, current_token_metadata: request.token_metadata, credential_changed: false },
    can_approve: true,
    approve_url: '/approve',
  });
  expect(screen.queryByRole('region', { name: 'Current token authority' })).not.toBeInTheDocument();
  expect(screen.queryByText('Approved pinned SHA')).not.toBeInTheDocument();
  expect(screen.queryByText('Branch SHA observed at approval')).not.toBeInTheDocument();
  expect(screen.getByText(/Approving runs all code/)).toBeVisible();
});

test('changed credential approval errors and previous approval evidence remain visible', async () => {
  render(GithubImport, {
    ...props,
    github_import: {
      ...request,
      status: 'failed',
      approved_commit_sha: 'reviewed-sha',
      observed_branch_sha_at_approval: 'newer-observed-sha',
      approved_credential_fingerprint: 'previous-fingerprint',
      credential_changed: true,
      approved_at: '2026-10-06T09:00:00Z',
      approved_by_name: 'Reviewer',
      approval_error: 'Credential changed; site-admin reapproval required.',
      last_error: 'Import stopped safely.',
    },
    can_approve: true,
    approve_url: '/approve',
  });
  expect(screen.getByText('reviewed-sha')).toBeVisible();
  expect(screen.getByText('newer-observed-sha')).toBeVisible();
  expect(screen.getByText('Pinned reviewed revision')).toBeVisible();
  expect(screen.getByText('Branch SHA observed at approval')).toBeVisible();
  expect(screen.getByText('previous-fingerprint')).toBeVisible();
  expect(screen.getByText('Credential changed; site-admin reapproval required.')).toBeVisible();
  expect(screen.getByText('Import stopped safely.')).toBeVisible();
  expect(screen.getByText(/credential has changed since this request/)).toBeVisible();
  expect(screen.getByRole('button', { name: 'Reapprove and retry import' })).toBeDisabled();
});

test('classic credentials also block the admin approval checkbox', () => {
  render(GithubImport, {
    ...props,
    github_import: { ...request, token_metadata: { token_kind: 'classic', oauth_scopes: ['repo'] } },
    can_approve: true,
    approve_url: '/approve',
  });
  expect(screen.getByRole('checkbox')).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Approve repository execution' })).toBeDisabled();
});

test.each(['approved', 'provisioning', 'ready'])('%s does not offer duplicate execution approval', (status) => {
  render(GithubImport, {
    ...props,
    github_import: { ...request, status, approval_valid: true, agent_edit_url: '/resident/edit' },
    can_approve: true,
    approve_url: '/approve',
  });
  expect(screen.getByRole('link', { name: 'Open resident settings' })).toHaveAttribute('href', '/resident/edit');
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
});

test('polls setup props only and cleans up its timer on navigation', async () => {
  vi.useFakeTimers();
  try {
    const { unmount } = render(GithubImport, { ...props, github_import: { ...request, status: 'provisioning' } });
    await vi.advanceTimersByTimeAsync(5000);
    expect(router.reload).toHaveBeenCalledWith({
      only: ['github_import', 'approve_url', 'can_approve', 'refresh_url', 'retry_activation_url'],
      preserveScroll: true,
    });
    unmount();
    router.reload.mockClear();
    await vi.advanceTimersByTimeAsync(5000);
    expect(router.reload).not.toHaveBeenCalled();
  } finally {
    vi.useRealTimers();
  }
});

test('terminal failures do not poll indefinitely', async () => {
  vi.useFakeTimers();
  try {
    render(GithubImport, { ...props, github_import: { ...request, status: 'failed' } });
    await vi.advanceTimersByTimeAsync(15000);
    expect(router.reload).not.toHaveBeenCalled();
  } finally {
    vi.useRealTimers();
  }
});
