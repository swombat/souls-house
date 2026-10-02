<script>
  import { onMount } from 'svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { CheckCircle, Circle, SpinnerGap, Warning, ArrowRight, Gear } from 'phosphor-svelte';
  import { agentIconFor } from '$lib/agent-icons';
  import { useSync } from '$lib/use-sync';
  import { accountAgentsPath, editAccountAgentPath, newAccountChatPath } from '@/routes';
  import { siteName } from '$lib/branding';

  let {
    agent,
    account,
    provisioning_retry_url: provisioningRetryUrl,
    orientation_retry_url: orientationRetryUrl,
  } = $props();

  useSync({ [`Agent:${agent.id}`]: 'agent' });

  let retryingProvisioning = $state(false);
  let retryingOrientation = $state(false);
  let AgentIcon = $derived(agentIconFor(agent.icon));
  let setupFailed = $derived(agent.runtime === 'provisioning' && Boolean(agent.sandbox_last_error));
  let runtimeReady = $derived(agent.runtime === 'external' && agent.health_state === 'healthy');
  let orientationStarted = $derived(Boolean(agent.orientation_requested_at));
  let orientationFinished = $derived(Boolean(agent.orientation_completed_at));
  let orientationFailed = $derived(Boolean(agent.orientation_last_error));
  let stages = $derived([
    {
      label: 'Beginning recorded',
      detail: 'The write-once seed and resident record are committed.',
      done: Boolean(agent.birth_committed_at),
    },
    {
      label: 'Home prepared',
      detail: 'The persistent identity volume has been seeded.',
      done: Boolean(agent.identity_seeded_at),
    },
    { label: 'Runtime ready', detail: 'The hosted Chaos runtime passed its health check.', done: runtimeReady },
    {
      label: 'First wake offered',
      detail: orientationFinished
        ? 'The first-wake orientation completed.'
        : orientationFailed
          ? 'The first-wake orientation did not complete and can be offered again.'
          : orientationStarted
            ? 'The resident may still be looking around.'
            : 'A gentle orientation will be queued after the runtime is healthy.',
      done: orientationStarted,
    },
  ]);

  onMount(() => {
    const interval = setInterval(() => {
      if (!orientationFinished && !orientationFailed && !setupFailed) {
        router.reload({ only: ['agent'], preserveScroll: true });
      }
    }, 3000);
    return () => clearInterval(interval);
  });

  function retryProvisioning() {
    retryingProvisioning = true;
    router.post(provisioningRetryUrl, {}, { preserveScroll: true, onFinish: () => (retryingProvisioning = false) });
  }

  function retryOrientation() {
    retryingOrientation = true;
    router.post(orientationRetryUrl, {}, { preserveScroll: true, onFinish: () => (retryingOrientation = false) });
  }
</script>

<svelte:head>
  <title>Preparing {agent.name}</title>
</svelte:head>

<div class="mx-auto max-w-3xl px-4 py-10 sm:px-8">
  <div class="mb-8 flex items-start gap-4">
    <div
      class="rounded-xl p-3 transition-all {agent.colour
        ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900`
        : 'bg-primary/10'} {runtimeReady ? 'ring-2 ring-primary/30' : ''}">
      <AgentIcon
        class="size-8 {agent.colour ? `text-${agent.colour}-700 dark:text-${agent.colour}-300` : 'text-primary'}"
        weight="duotone" />
    </div>
    <div>
      <p class="text-sm font-medium text-primary">Resident creation</p>
      <h1 class="mt-1 text-3xl font-bold">{runtimeReady ? agent.name : `Preparing ${agent.name}`}</h1>
      <p class="mt-2 text-muted-foreground">You can close this page. Setup will continue in the background.</p>
    </div>
  </div>

  {#if setupFailed}
    <Alert variant="destructive" class="mb-6">
      <Warning class="size-4" />
      <AlertTitle>Setup paused</AlertTitle>
      <AlertDescription>
        The beginning is safely committed, but the runtime could not be prepared. Retrying will preserve the same seed
        and any existing identity volume.
      </AlertDescription>
    </Alert>
  {/if}

  <Card>
    <CardHeader>
      <CardTitle
        >{runtimeReady
          ? 'They are online'
          : setupFailed
            ? 'Their beginning is safe'
            : 'Bringing them online'}</CardTitle>
      <CardDescription>
        {#if runtimeReady}
          Their runtime, files, and offered memory scaffold are ready.
        {:else if setupFailed}
          Infrastructure failed after the birth commit. The soul seed remains read-only and retryable.
        {:else}
          {$siteName} is preparing a persistent home and runtime.
        {/if}
      </CardDescription>
    </CardHeader>
    <CardContent class="space-y-6">
      <ol>
        {#each stages as stage, index}
          <li class="relative flex gap-4 pb-6 last:pb-0">
            {#if index < stages.length - 1}
              <div
                class="absolute left-3 top-7 h-[calc(100%-1.25rem)] w-px {stage.done ? 'bg-primary/40' : 'bg-border'}">
              </div>
            {/if}
            <div class="relative mt-0.5">
              {#if stage.done}
                <CheckCircle class="size-6 text-primary" weight="fill" />
              {:else if !setupFailed && stages.slice(0, index).every((item) => item.done)}
                <SpinnerGap class="size-6 animate-spin text-primary" />
              {:else}
                <Circle class="size-6 text-muted-foreground/40" />
              {/if}
            </div>
            <div>
              <p class="font-medium {stage.done ? '' : 'text-muted-foreground'}">{stage.label}</p>
              <p class="mt-1 text-sm text-muted-foreground">{stage.detail}</p>
            </div>
          </li>
        {/each}
      </ol>

      {#if setupFailed}
        <div class="rounded-lg border border-destructive/30 bg-destructive/5 p-4">
          <p class="text-sm font-medium">Setup detail</p>
          <p class="mt-2 break-words font-mono text-xs text-muted-foreground">{agent.sandbox_last_error}</p>
          <Button class="mt-4" onclick={retryProvisioning} disabled={retryingProvisioning}>
            {retryingProvisioning ? 'Retrying…' : 'Try setup again'}
          </Button>
        </div>
      {:else if runtimeReady && agent.inference_setup_message}
        <div role="status" class="rounded-lg border border-destructive/30 bg-destructive/5 p-4">
          <p class="font-medium">Their first wake needs attention</p>
          <p class="mt-1 text-sm text-muted-foreground">{agent.inference_setup_message}</p>
          <a class="mt-3 inline-block text-primary underline" href={editAccountAgentPath(account.id, agent.id)}>
            Edit {agent.name}
          </a>
        </div>
      {:else if runtimeReady && orientationFailed}
        <div class="rounded-lg border border-destructive/30 bg-destructive/5 p-4">
          <p class="font-medium">Their first wake did not complete</p>
          <p class="mt-1 text-sm text-muted-foreground">
            The runtime is online. You can retry orientation or begin a conversation without waiting for it.
          </p>

          <Button class="mt-4" variant="outline" onclick={retryOrientation} disabled={retryingOrientation}>
            {retryingOrientation ? 'Queueing…' : 'Try orientation again'}
          </Button>
        </div>
      {:else if runtimeReady && orientationStarted && !orientationFinished}
        <div class="rounded-lg border bg-muted/30 p-4">
          <p class="font-medium">Their first wake is in progress</p>
          <p class="mt-1 text-sm text-muted-foreground">
            Invocations are serialized, so a conversation started now will wait safely behind orientation rather than
            overlap with it.
          </p>
        </div>
      {:else if runtimeReady && !orientationStarted}
        <div class="rounded-lg border bg-muted/30 p-4">
          <p class="font-medium">The runtime is ready, but orientation has not started yet.</p>
          <Button class="mt-4" variant="outline" onclick={retryOrientation} disabled={retryingOrientation}>
            {retryingOrientation ? 'Queueing…' : 'Offer the first wake'}
          </Button>
        </div>
      {/if}

      <div class="flex flex-wrap gap-3 border-t pt-6">
        {#if runtimeReady}
          <a href={newAccountChatPath(account.id)}>
            <Button>
              Start your first conversation
              <ArrowRight class="ml-2 size-4" />
            </Button>
          </a>
        {/if}
        <a href={editAccountAgentPath(account.id, agent.id)}>
          <Button variant="outline">
            <Gear class="mr-2 size-4" />
            Resident settings
          </Button>
        </a>
        <a href={accountAgentsPath(account.id)}>
          <Button variant="ghost">All residents</Button>
        </a>
      </div>
    </CardContent>
  </Card>
</div>
