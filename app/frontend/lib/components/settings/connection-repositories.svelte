<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';

  // The GitHub card's Repositories section: repositories connected for
  // watches, and under each the watches residents or people armed on it.
  let { connection } = $props();
  let fullName = $state('');

  let repositories = $derived(connection.repositories || []);
  let canManage = $derived(Boolean(connection.can_manage_repositories));
  let canConnect = $derived(canManage && connection.status === 'connected');

  function connectRepository(event) {
    event.preventDefault();
    const name = fullName.trim();
    if (!name) return;
    router.post(
      connection.repositories_url,
      { service_connection_id: connection.id, full_name: name },
      { preserveScroll: true, onSuccess: () => (fullName = '') }
    );
  }

  function disconnectRepository(repository) {
    const armed = repository.armed_watches || 0;
    const warning =
      armed > 0
        ? `Disconnect ${repository.full_name}? Its ${armed} armed ${armed === 1 ? 'watch is' : 'watches are'} cancelled and the house removes its hook on GitHub.`
        : `Disconnect ${repository.full_name}? The house removes its hook on GitHub.`;
    if (confirm(warning)) router.delete(repository.url, { preserveScroll: true });
  }

  function cancelWatch(watch) {
    if (confirm(`Cancel the watch on ${watch.repository}? Nothing is posted.`))
      router.delete(watch.cancel_url, { preserveScroll: true });
  }

  function formatTime(value) {
    if (!value) return null;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  }

  const hookLabels = {
    installed: 'Installed',
    installing: 'Waiting for GitHub',
    manual: 'Needs manual setup',
    failed: 'Failed',
    removed: 'Removed',
  };

  function hookClass(status) {
    if (status === 'installed') return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-200';
    if (status === 'failed') return 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-200';
    return 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-200';
  }

  function watchTarget(watch) {
    const filter = watch.filter || {};
    const sha = filter.head_sha ? filter.head_sha.slice(0, 7) : null;
    if (watch.event === 'workflow_run') {
      return [filter.workflow_name ? `${filter.workflow_name} for` : 'CI for', sha].filter(Boolean).join(' ');
    }
    return ['Deployment', filter.environment ? `to ${filter.environment}` : null, sha ? `at ${sha}` : null]
      .filter(Boolean)
      .join(' ');
  }

  function watchCreator(watch) {
    if (!watch.created_by) return 'unknown';
    return watch.created_by.type === 'resident' ? `${watch.created_by.name} (resident)` : watch.created_by.name;
  }

  function watchStateClass(watch) {
    if (watch.status === 'status not established') return 'text-amber-700';
    if (watch.state === 'armed') return 'text-sky-700';
    if (watch.state === 'fulfilled') return 'text-emerald-700';
    if (watch.state === 'undeliverable') return 'text-red-700';
    return 'text-muted-foreground';
  }
</script>

<section class="space-y-4 border-t pt-4" aria-labelledby={`repositories-${connection.id}`} data-testid="repositories">
  <div>
    <h4 id={`repositories-${connection.id}`} class="font-medium">Repositories</h4>
    <p class="text-sm text-muted-foreground">
      Connected repositories tell the house when a workflow or deployment finishes, so a watch can post the result in a
      conversation and wake the resident that asked.
    </p>
  </div>

  {#if repositories.length === 0}
    <p class="text-sm text-muted-foreground">No repositories connected for watches yet.</p>
  {/if}

  <ul class="space-y-3">
    {#each repositories as repository (repository.id)}
      <li class="space-y-3 rounded-lg border p-4" data-testid={`repository-${repository.full_name}`}>
        <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
          <div class="min-w-0 space-y-1">
            <p class="flex flex-wrap items-center gap-2">
              <span class="truncate font-medium">{repository.full_name}</span>
              <span class={`rounded-full px-2 py-0.5 text-xs font-medium ${hookClass(repository.hook_status)}`}>
                {hookLabels[repository.hook_status] || repository.hook_status}
              </span>
            </p>
            <p class="text-sm text-muted-foreground">
              {#if repository.last_delivery_at}
                Last delivery {formatTime(repository.last_delivery_at)}: {repository.last_delivery_result}
              {:else}
                No delivery received yet
              {/if}
            </p>
            {#if repository.hook_status === 'failed' && repository.hook_error}
              <p class="text-sm text-red-700">{repository.hook_error}</p>
            {:else if repository.hook_status === 'manual'}
              <p class="text-sm text-amber-700">
                {repository.hook_error || 'GitHub refused to install the hook; an admin of the repository must add it.'}
              </p>
            {/if}
          </div>
          {#if canManage}
            <Button
              type="button"
              variant="outline"
              size="sm"
              class="shrink-0 border-destructive/20 text-destructive shadow-none hover:bg-destructive/10 hover:text-destructive"
              aria-label={`Disconnect ${repository.full_name}`}
              onclick={() => disconnectRepository(repository)}>
              Disconnect
            </Button>
          {/if}
        </div>

        {#if repository.setup && repository.hook_status !== 'installing'}
          <div class="space-y-2 rounded-md bg-muted/50 p-3 text-sm" data-testid="manual-setup">
            <p>
              An admin of {repository.full_name} can add the webhook under Settings → Webhooks on GitHub. Content type
              <code>application/json</code>; events: workflow runs and deployment statuses. It counts as installed once
              GitHub's ping arrives.
            </p>
            <dl class="grid gap-1 sm:grid-cols-[auto_1fr] sm:gap-x-3">
              <dt class="text-muted-foreground">Payload URL</dt>
              <dd><code class="break-all">{repository.setup.url}</code></dd>
              <dt class="text-muted-foreground">Secret</dt>
              <dd><code class="break-all">{repository.setup.secret}</code></dd>
            </dl>
          </div>
        {/if}

        {#if repository.watches && repository.watches.length > 0}
          <ul class="divide-y rounded-md border text-sm" aria-label={`Watches on ${repository.full_name}`}>
            {#each repository.watches as watch (watch.id)}
              <li class="flex flex-col gap-2 p-3 sm:flex-row sm:items-center sm:justify-between">
                <div class="min-w-0 space-y-0.5">
                  <p>
                    <span class="font-medium">{watchTarget(watch)}</span>
                    <span class={`ml-2 ${watchStateClass(watch)}`}>{watch.status || watch.state}</span>
                  </p>
                  <p class="text-muted-foreground">
                    Armed by {watchCreator(watch)} · posts in
                    {#if watch.chat_url}
                      <a class="underline hover:text-foreground" href={watch.chat_url}>{watch.chat_title}</a>
                    {:else}
                      {watch.chat_title || watch.chat_id}
                    {/if}
                    {#if watch.state === 'armed'}
                      · expires {formatTime(watch.expires_at)}
                    {:else if watch.fulfilled_at}
                      · {formatTime(watch.fulfilled_at)}
                    {/if}
                  </p>
                  {#if watch.status === 'status not established' && watch.reconcile_error}
                    <p class="text-amber-700">Could not establish status on GitHub: {watch.reconcile_error}</p>
                  {:else if watch.state === 'undeliverable' && watch.undeliverable_reason}
                    <p class="text-red-700">{watch.undeliverable_reason}</p>
                  {/if}
                </div>
                {#if watch.state === 'armed' && watch.cancel_url}
                  <Button type="button" variant="outline" size="sm" class="shrink-0" onclick={() => cancelWatch(watch)}>
                    Cancel watch
                  </Button>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
      </li>
    {/each}
  </ul>

  {#if canConnect}
    <form class="flex flex-col gap-2 sm:flex-row sm:items-end" onsubmit={connectRepository}>
      <label class="flex flex-1 flex-col gap-1 text-sm">
        <span>Watch a repository</span>
        <input
          type="text"
          name="full_name"
          class="rounded-md border bg-background px-3 py-2"
          placeholder="owner/name"
          autocomplete="off"
          required
          bind:value={fullName} />
      </label>
      <Button type="submit" size="sm" disabled={!fullName.trim()}>Connect repository</Button>
    </form>
  {:else if !canManage}
    <p class="text-sm text-muted-foreground">
      Only someone who can manage or provision this GitHub connection can connect repositories.
    </p>
  {/if}
</section>
