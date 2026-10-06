<script>
  import { onMount } from 'svelte';
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import GithubTokenAuthority from '$lib/components/agents/github-token-authority.svelte';
  import GithubImportApproval from '$lib/components/agents/github-import-approval.svelte';
  import GithubImportStatus from '$lib/components/agents/github-import-status.svelte';
  import { accountAgentsPath, accountPersonalServicesPath } from '@/routes';

  let {
    account,
    github_import: request = null,
    connections = [],
    models = [],
    submit_url: submitUrl,
    approve_url: approveUrl = null,
    can_approve: canApprove = false,
    refresh_url: refreshUrl = null,
    retry_activation_url: retryActivationUrl = null,
    runtime_trust_notice: runtimeTrustNotice = '',
    future_branch_trust_notice: futureBranchTrustNotice = '',
  } = $props();

  let form = useForm({
    github_resident_import: {
      name: '',
      model_id: models[0]?.model_id || '',
      service_connection_id: connections[0]?.id || '',
      branch: '',
    },
  });
  let selectedConnection = $derived(
    connections.find(
      (connection) => String(connection.id) === String($form.github_resident_import.service_connection_id)
    )
  );
  let eligible = $derived(selectedConnection?.token_metadata?.token_kind === 'fine_grained');
  let canSubmit = $derived(
    !request &&
      eligible &&
      $form.github_resident_import.name.trim() &&
      $form.github_resident_import.model_id &&
      !$form.processing
  );

  function submit() {
    if (!canSubmit) return;
    $form.post(submitUrl);
  }

  function errorsFor(field) {
    const errors = $form.errors[field] || $form.errors[`github_resident_import.${field}`];
    return Array.isArray(errors) ? errors.join(' ') : errors;
  }

  onMount(() => {
    const interval = setInterval(() => {
      if (request && ['pending_review', 'approved', 'provisioning'].includes(request.status)) {
        router.reload({
          only: ['github_import', 'approve_url', 'can_approve', 'refresh_url', 'retry_activation_url'],
          preserveScroll: true,
        });
      }
    }, 5000);
    return () => clearInterval(interval);
  });
</script>

<svelte:head>
  <title>{request ? `Import ${request.name}` : 'Bring a GitHub resident'}</title>
</svelte:head>

<div class="mx-auto max-w-3xl space-y-6 px-4 py-8 sm:px-8">
  <a class="text-sm text-primary underline" href={accountAgentsPath(account.id)}>Back to residents</a>
  <header>
    <h1 class="text-3xl font-bold">{request ? request.name : 'Bring an existing GitHub resident'}</h1>
    <p class="mt-2 text-muted-foreground">
      Bring an existing portable home, not a new soul seed. The repository must already have a compatible
      <code>portable_v1</code> <code>resident-home.json</code> manifest.
    </p>
    <a
      class="mt-3 inline-block text-sm text-primary underline"
      href="https://github.com/swombat/souls-house/blob/master/docs/features/github-resident-onboarding.md"
      target="_blank"
      rel="noopener noreferrer">Manifest and local harness guide</a>
  </header>
  <div class="space-y-2 rounded-lg border bg-muted/30 p-4 text-sm">
    <p>
      Your local harness remains separate. This import does not stop it, replace its configuration, or move your
      external memory graph into the house.
    </p>
    <p>Repository code cannot execute here until a site administrator approves this branch and its future pushes.</p>
  </div>

  {#if request}
    <GithubImportStatus {request} {retryActivationUrl} {runtimeTrustNotice} />
    <GithubTokenAuthority metadata={request.token_metadata} title="Reviewed token authority" />
    {#if request.current_token_metadata}
      <GithubTokenAuthority metadata={request.current_token_metadata} title="Current token authority" />
    {/if}
    <GithubImportApproval {request} {approveUrl} {canApprove} {refreshUrl} {futureBranchTrustNotice} />
  {:else if connections.length === 0}
    <section class="space-y-3 rounded-lg border p-5">
      <h2 class="text-lg font-semibold">Connect the identity repository first</h2>
      <p class="text-sm text-muted-foreground">
        No GitHub connection is available for you to provision. Connect a repository-specific fine-grained token, or ask
        an account owner or administrator for access.
      </p>
      <Button href={accountPersonalServicesPath(account.id)} variant="outline">Open personal services</Button>
    </section>
  {:else}
    <form
      class="space-y-5 rounded-lg border p-5"
      onsubmit={(event) => {
        event.preventDefault();
        submit();
      }}>
      <h2 class="text-lg font-semibold">Prepare an import request</h2>
      {#if errorsFor('base')}
        <p role="alert" class="text-sm text-destructive">{errorsFor('base')}</p>
      {/if}
      <label class="block space-y-2">
        <span class="text-sm font-medium">GitHub connection</span>
        <select
          class="w-full rounded-md border bg-background p-2"
          bind:value={$form.github_resident_import.service_connection_id}
          disabled={$form.processing}>
          {#each connections as connection}
            <option value={connection.id}>{connection.label} · {connection.repository}</option>
          {/each}
        </select>
      </label>
      {#if errorsFor('service_connection_id')}
        <p role="alert" class="text-sm text-destructive">{errorsFor('service_connection_id')}</p>
      {/if}
      <GithubTokenAuthority metadata={selectedConnection?.token_metadata} />
      <label class="block space-y-2">
        <span class="text-sm font-medium">Resident display name</span>
        <input
          class="w-full rounded-md border bg-background px-3 py-2"
          bind:value={$form.github_resident_import.name}
          maxlength="100"
          required
          disabled={$form.processing} />
      </label>
      {#if errorsFor('name')}
        <p role="alert" class="text-sm text-destructive">{errorsFor('name')}</p>
      {/if}
      <label class="block space-y-2">
        <span class="text-sm font-medium">Model</span>
        <select
          class="w-full rounded-md border bg-background p-2"
          bind:value={$form.github_resident_import.model_id}
          disabled={$form.processing}
          required>
          {#each models as model}
            <option value={model.model_id}>{model.label}</option>
          {/each}
        </select>
      </label>
      {#if errorsFor('model_id')}
        <p role="alert" class="text-sm text-destructive">{errorsFor('model_id')}</p>
      {/if}
      <label class="block space-y-2">
        <span class="text-sm font-medium">Branch (optional)</span>
        <input
          class="w-full rounded-md border bg-background px-3 py-2"
          bind:value={$form.github_resident_import.branch}
          placeholder="Repository default branch"
          disabled={$form.processing} />
      </label>
      <p class="text-sm text-muted-foreground">
        Leave blank to use the repository's default branch, resolved by the server.
      </p>
      {#if errorsFor('branch')}
        <p role="alert" class="text-sm text-destructive">{errorsFor('branch')}</p>
      {/if}
      <p class="text-sm text-muted-foreground">
        Submitting requests review; it does not approve or run repository code.
      </p>
      <Button type="submit" disabled={!canSubmit}
        >{$form.processing ? 'Submitting…' : 'Request site-admin review'}</Button>
    </form>
  {/if}
</div>
