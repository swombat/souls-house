<script>
  import { onDestroy } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Card, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { RocketLaunch, ArrowSquareOut } from 'phosphor-svelte';
  import { runLabel, shouldPoll, expiryWarning } from './deploys.js';

  let { workflows = [], repo = '', deploy_status = null, flash = {} } = $props();
  let sending = $state(null);
  let requestedAt = $state(0);

  const status = $derived(deploy_status || { configured: false, runs: [] });
  const expiry = $derived(expiryWarning(status.token_expires_at));

  function deploy(workflow) {
    if (!confirm(`Run "${workflow.name}" on master now?`)) return;
    sending = workflow.key;
    router.post(
      '/admin/deploys',
      { workflow: workflow.key },
      {
        onSuccess: () => (requestedAt = Date.now()),
        onFinish: () => (sending = null),
      }
    );
  }

  // Poll while a run is in flight or just after a request (GitHub takes a few
  // seconds to list a new run). A Rails deploy restarts this app, so check
  // /up first rather than letting Inertia show an error page mid-restart.
  async function tick() {
    if (!shouldPoll(status.runs, requestedAt, Date.now())) return;
    try {
      const up = await fetch('/up', { cache: 'no-store' });
      if (!up.ok) return;
    } catch {
      return;
    }
    router.reload({ only: ['deploy_status'], preserveScroll: true });
  }

  const timer = setInterval(tick, 8000);
  onDestroy(() => clearInterval(timer));
</script>

<div class="container mx-auto max-w-2xl py-8 px-4">
  <h1 class="text-2xl font-bold mb-1">Deploy</h1>
  <p class="text-sm text-muted-foreground mb-6">
    Runs the GitHub Actions deploy workflows on <code>{repo}</code> at <code>master</code>.
  </p>

  {#if flash?.notice}
    <div class="mb-4 rounded-md bg-green-50 dark:bg-green-950 p-3 text-sm text-green-700 dark:text-green-300">
      {flash.notice}
    </div>
  {/if}
  {#if flash?.alert}
    <div class="mb-4 rounded-md bg-red-50 dark:bg-red-950 p-3 text-sm text-red-700 dark:text-red-300">
      {flash.alert}
    </div>
  {/if}

  {#if !status.configured}
    <div class="mb-4 rounded-md border p-3 text-sm" data-testid="deploy-unconfigured">
      No deploy token is configured. Add a fine-grained PAT (this repository only, Actions: read and write) at
      <code>github.deploy_token</code> in the production credentials.
    </div>
  {:else}
    {#if status.error}
      <div class="mb-4 rounded-md bg-red-50 dark:bg-red-950 p-3 text-sm text-red-700 dark:text-red-300">
        {status.error}
      </div>
    {/if}
    {#if expiry}
      <div class="mb-4 rounded-md bg-amber-50 dark:bg-amber-950 p-3 text-sm text-amber-800 dark:text-amber-200">
        {expiry}
      </div>
    {/if}
  {/if}

  <div class="space-y-3">
    {#each workflows as workflow (workflow.key)}
      <Card>
        <CardHeader class="pb-3">
          <div class="flex items-center justify-between gap-3">
            <CardTitle class="text-base">{workflow.name}</CardTitle>
            <Button
              variant="outline"
              size="sm"
              disabled={!status.configured || sending !== null}
              onclick={() => deploy(workflow)}>
              <RocketLaunch class="mr-1.5 size-3.5" />
              {sending === workflow.key ? 'Requesting…' : 'Run'}
            </Button>
          </div>
          <CardDescription>{workflow.description}</CardDescription>
        </CardHeader>
      </Card>
    {/each}
  </div>

  {#if status.configured}
    <h2 class="text-lg font-semibold mt-8 mb-3">Recent runs</h2>
    {#if status.runs.length === 0}
      <p class="text-sm text-muted-foreground">No manual deploy runs found.</p>
    {:else}
      <ul class="divide-y rounded-md border text-sm" data-testid="deploy-runs">
        {#each status.runs as run (run.id)}
          <li class="flex items-center justify-between gap-3 px-3 py-2">
            <div class="min-w-0">
              <div class="font-medium">{run.name}</div>
              <div class="text-xs text-muted-foreground truncate">
                {run.head_sha} · {run.actor || '?'} · {new Date(run.created_at).toLocaleString()}
              </div>
            </div>
            <a href={run.url} target="_blank" rel="noopener" class="flex items-center gap-1 shrink-0 hover:underline">
              {runLabel(run)}
              <ArrowSquareOut class="size-3.5" />
            </a>
          </li>
        {/each}
      </ul>
    {/if}
  {/if}
</div>
