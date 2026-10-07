<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';

  let { request, approveUrl, canApprove = false, refreshUrl = null, futureBranchTrustNotice } = $props();
  let confirmed = $state(false);
  let submitting = $state(false);
  let refreshing = $state(false);
  let actionError = $state('');
  let eligible = $derived(
    request.token_metadata?.token_kind === 'fine_grained' &&
      (!request.current_token_metadata || request.current_token_metadata.token_kind === 'fine_grained') &&
      !request.credential_changed &&
      Boolean(request.review_revision)
  );
  let reviewable = $derived(['pending_review', 'failed'].includes(request.status));
  let refreshable = $derived(['pending_review', 'needs_runtime_trust', 'ready', 'failed'].includes(request.status));
  let approvalKey = $derived(
    `${request.id}:${request.review_revision}:${request.commit_sha}:${request.current_credential_fingerprint}:${request.credential_fingerprint}:${request.credential_changed}:${request.status}`
  );
  $effect(() => {
    approvalKey;
    confirmed = false;
  });

  function approve() {
    if (!confirmed || submitting || refreshing || !eligible || !reviewable || !canApprove || !approveUrl) return;
    submitting = true;
    actionError = '';
    router.post(
      approveUrl,
      { confirmed: 'true', review_revision: request.review_revision },
      {
        preserveScroll: true,
        onError: (errors) => {
          confirmed = false;
          actionError = failureMessage('Approval was rejected.', errors);
        },
        onFinish: () => (submitting = false),
      }
    );
  }

  function refreshReview() {
    if (submitting || refreshing || !refreshable || !refreshUrl) return;
    refreshing = true;
    actionError = '';
    router.post(
      refreshUrl,
      {},
      {
        preserveScroll: true,
        onError: (errors) => (actionError = failureMessage('Review refresh failed.', errors)),
        onFinish: () => (refreshing = false),
      }
    );
  }

  function failureMessage(prefix, errors) {
    const detail = Object.values(errors || {})
      .flat()
      .filter((value) => typeof value === 'string')
      .join(' ');
    return `${prefix} ${detail || 'Check your permissions and refresh the review before trying again.'}`;
  }
</script>

<section class="space-y-4 rounded-lg border p-5" aria-label="Repository execution approval">
  <h2 class="text-lg font-semibold">Account execution approval</h2>
  <p class="text-sm">
    Approving runs all code in <strong>{request.repository}@{request.branch}</strong>, now and on every future push,
    with this token.
  </p>
  <dl class="grid gap-2 text-sm sm:grid-cols-[auto_1fr]">
    <dt class="text-muted-foreground">Pinned reviewed revision</dt>
    <dd class="break-all font-mono">{request.commit_sha || 'Not resolved yet'}</dd>
    <dt class="text-muted-foreground">Request credential fingerprint</dt>
    <dd class="break-all font-mono">{request.credential_fingerprint || 'Not available'}</dd>
    {#if request.credential_changed}
      <dt class="text-muted-foreground">Current credential fingerprint</dt>
      <dd class="break-all font-mono">{request.current_credential_fingerprint || 'Not available'}</dd>
    {/if}
    {#if request.approved_at}
      <dt class="text-muted-foreground">Approved pinned SHA</dt>
      <dd class="break-all font-mono">{request.approved_commit_sha}</dd>
      <dt class="text-muted-foreground">Branch SHA observed at approval</dt>
      <dd class="break-all font-mono">{request.observed_branch_sha_at_approval}</dd>
      <dt class="text-muted-foreground">Approved credential fingerprint</dt>
      <dd class="break-all font-mono">{request.approved_credential_fingerprint}</dd>
      <dt class="text-muted-foreground">Approved by</dt>
      <dd>{request.approved_by_name || 'Account manager'} · {request.approved_at}</dd>
    {/if}
  </dl>
  <p class="text-sm text-muted-foreground">
    A changed credential requires account reapproval by someone who can provision this connection. Fingerprints identify
    the credential without displaying the token. Approval also becomes invalid if the approver loses current permission
    to manage the account or provision this connection.
  </p>
  <p class="text-sm text-muted-foreground">
    Initial setup uses the approved pinned revision. The branch revision observed at approval may be newer; approval
    also trusts subsequent pushes to this branch.
  </p>
  {#if request.credential_changed}
    <p role="alert" class="text-sm text-destructive">
      The credential has changed since this request was prepared. Account reapproval is required before execution.
    </p>
  {/if}
  {#if request.approval_error}
    <p role="alert" class="text-sm text-destructive">{request.approval_error}</p>
  {/if}
  {#if actionError}
    <p role="alert" class="text-sm text-destructive">{actionError}</p>
  {/if}
  {#if request.approval_valid}
    <p class="text-sm font-medium">Approval is valid for this credential and future branch pushes.</p>
  {:else}
    <p class="text-sm font-medium">Execution is not approved for the current credential.</p>
  {/if}

  {#if refreshUrl && refreshable}
    <p class="text-sm text-muted-foreground">
      Refresh review to check the current branch and credential authority using this same request and resident. Their
      existing home is preserved. Execution still requires explicit account approval afterward.
    </p>
    <Button variant="outline" onclick={refreshReview} disabled={refreshing || submitting}>
      {refreshing ? 'Refreshing…' : 'Refresh review'}
    </Button>
  {/if}
  {#if futureBranchTrustNotice}
    <p class="text-sm">{futureBranchTrustNotice}</p>
  {/if}
  {#if canApprove && approveUrl && reviewable}
    <label class="flex items-start gap-3 text-sm">
      <input type="checkbox" bind:checked={confirmed} disabled={submitting || refreshing || !eligible} class="mt-1" />
      <span>
        I approve execution of all code and hooks from this repository branch, including future pushes, with broad
        runtime privileges. I have reviewed the repository and this credential's authority.
      </span>
    </label>
    <Button onclick={approve} disabled={!confirmed || submitting || refreshing || !eligible}>
      {submitting
        ? 'Approving…'
        : request.status === 'failed'
          ? 'Reapprove and retry import'
          : 'Approve repository execution'}
    </Button>
  {:else if !request.approval_valid}
    <p class="text-sm text-muted-foreground">
      Someone with current permission to manage this account and provision the selected connection must approve this
      request before its code can execute.
    </p>
  {/if}
</section>
