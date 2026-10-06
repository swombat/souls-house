<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  let { request, retryActivationUrl = null, runtimeTrustNotice = '' } = $props();
  let retrying = $state(false);
  let retryError = $state('');
  const states = {
    pending_review: ['Waiting for site-admin review', 'No imported repository code is approved to run yet.'],
    approved: [
      'Approved; waiting for setup',
      'Site-admin approval is recorded. The resident home will be prepared next.',
    ],
    provisioning: [
      'Preparing the existing home',
      'The approved home is being prepared in its persistent resident runtime.',
    ],
    needs_runtime_trust: [
      'Home imported; operator trust step needed',
      'The files are preserved, but the resident is not online. A site operator must finish Chaos project trust before activation.',
    ],
    ready: [
      'Resident home is ready',
      'The existing home is prepared. Open resident settings to check inference and hosting.',
    ],
    failed: [
      'Import needs attention',
      'Setup did not complete. A site administrator can review and retry this request.',
    ],
  };
  let state = $derived(
    states[request.status] || ['Import status unavailable', 'Refresh this page to check setup status.']
  );

  function retryActivation() {
    if (retrying || !retryActivationUrl || !request.approval_valid) return;
    retrying = true;
    retryError = '';
    router.post(
      retryActivationUrl,
      {},
      {
        preserveScroll: true,
        onError: () => (retryError = 'Activation was not accepted. Check approval and the operator trust step.'),
        onFinish: () => (retrying = false),
      }
    );
  }
</script>

<section class="space-y-4 rounded-lg border p-5" aria-label="Import status">
  <div role="status" aria-live="polite">
    <h2 class="text-lg font-semibold">{state[0]}</h2>
    <p class="mt-1 text-sm text-muted-foreground">{state[1]}</p>
  </div>
  <dl class="grid gap-2 text-sm sm:grid-cols-[auto_1fr]">
    <dt class="text-muted-foreground">Repository</dt>
    <dd class="break-all">{request.repository}</dd>
    <dt class="text-muted-foreground">Branch</dt>
    <dd class="break-all">{request.branch || 'Resolving default branch'}</dd>
    <dt class="text-muted-foreground">Model</dt>
    <dd class="break-all">{request.model_id}</dd>
    <dt class="text-muted-foreground">Portable identity</dt>
    <dd class="break-all">{request.portable_home_id || 'Not resolved yet'}</dd>
  </dl>
  {#if request.last_error}
    <p role="alert" class="text-sm text-destructive">{request.last_error}</p>
  {/if}
  {#if request.status === 'needs_runtime_trust'}
    <p class="text-sm text-muted-foreground">{runtimeTrustNotice}</p>
    {#if retryActivationUrl}
      <Button onclick={retryActivation} disabled={retrying || !request.approval_valid}>
        {retrying ? 'Checking…' : 'Retry activation after operator trust'}
      </Button>
    {/if}
    {#if retryError}
      <p role="alert" class="text-sm text-destructive">{retryError}</p>
    {/if}
  {/if}
  {#if request.agent_edit_url}
    <Button href={request.agent_edit_url} variant="outline">Open resident settings</Button>
  {/if}
</section>
