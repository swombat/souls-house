<script>
  import ReviewStep from '$lib/components/agents/birth/review-step.svelte';
  import RuntimeStep from '$lib/components/agents/birth/runtime-step.svelte';
  import SoulSeedStep from '$lib/components/agents/birth/soul-seed-step.svelte';
  import AppearanceStep from '$lib/components/agents/birth/appearance-step.svelte';
  import BeginningStep from '$lib/components/agents/birth/beginning-step.svelte';
  import { onMount } from 'svelte';
  import { fly } from 'svelte/transition';
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  import { Card, CardFooter } from '$lib/components/shadcn/card';
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { ArrowLeft, ArrowRight, Check } from 'phosphor-svelte';

  import { accountAgentsPath } from '@/routes';

  let {
    grouped_models = {},
    default_model_id,
    colour_options = [],
    icon_options = [],
    account,
    resident_import_url: residentImportUrl = null,
    github_resident_import_url: githubResidentImportUrl = null,
  } = $props();

  const draftKey = `helixkit:agent-birth-draft:${account.id}`;
  const steps = ['Beginning', 'Appearance', 'Soul seed', 'Runtime', 'Review'];

  let step = $state(0);
  let selectedModel = $state(default_model_id);
  let openBeginning = $state(false);
  let acknowledged = $state(false);
  let draftReady = $state(false);

  let form = useForm({
    agent: {
      name: '',
      system_prompt: '',
      model_id: default_model_id,
      colour: null,
      icon: null,
      scheduled_wakes_enabled: true,
      open_beginning: false,
    },
  });

  let formComplete = $derived(
    $form.agent.name.trim().length > 0 &&
      ($form.agent.system_prompt.trim().length > 0 || openBeginning) &&
      selectedModel
  );
  let canContinue = $derived(
    step === 0 ||
      (step === 1 && $form.agent.name.trim().length > 0) ||
      (step === 2 && ($form.agent.system_prompt.trim().length > 0 || openBeginning)) ||
      step === 3
  );
  let canCreate = $derived(step === steps.length - 1 && formComplete && acknowledged && !$form.processing);

  onMount(() => {
    const saved = localStorage.getItem(draftKey);
    if (saved) {
      try {
        const draft = JSON.parse(saved);
        $form.agent.name = draft.name || '';
        $form.agent.system_prompt = draft.system_prompt || '';
        $form.agent.colour = draft.colour || null;
        $form.agent.icon = draft.icon || null;
        $form.agent.scheduled_wakes_enabled = draft.scheduled_wakes_enabled ?? true;
        selectedModel = draft.model_id || default_model_id;
        openBeginning = draft.open_beginning === true;
        $form.agent.open_beginning = openBeginning;
        step = Math.min(Math.max(draft.step || 0, 0), steps.length - 1);
      } catch {
        localStorage.removeItem(draftKey);
      }
    }
    draftReady = true;
  });

  $effect(() => {
    if (!draftReady || typeof localStorage === 'undefined') return;

    localStorage.setItem(
      draftKey,
      JSON.stringify({
        name: $form.agent.name,
        system_prompt: $form.agent.system_prompt,
        colour: $form.agent.colour,
        icon: $form.agent.icon,
        model_id: selectedModel,
        scheduled_wakes_enabled: $form.agent.scheduled_wakes_enabled,
        open_beginning: openBeginning,
        step,
      })
    );
  });

  function next() {
    if (canContinue && step < steps.length - 1) step += 1;
  }

  function back() {
    if (step > 0) step -= 1;
  }

  function createAgent() {
    if (!canCreate) return;

    $form.agent.model_id = selectedModel;
    $form.agent.open_beginning = openBeginning;
    if (openBeginning) $form.agent.system_prompt = '';
    $form.post(accountAgentsPath(account.id), {
      onSuccess: () => localStorage.removeItem(draftKey),
    });
  }

  function cancel() {
    if (confirm('Discard this uncommitted resident draft?')) {
      localStorage.removeItem(draftKey);
      router.visit(accountAgentsPath(account.id));
    }
  }
</script>

<svelte:head>
  <title>Begin a resident</title>
</svelte:head>

<div class="mx-auto max-w-4xl px-4 py-8 sm:px-8">
  <div class="mb-8">
    {#if githubResidentImportUrl}
      <p class="mb-4 text-sm">
        <a class="text-primary underline" href={githubResidentImportUrl}>Bring an existing GitHub resident instead</a>
      </p>
    {/if}
    {#if residentImportUrl}
      <p class="mb-4 text-sm">
        <a class="text-primary underline" href={residentImportUrl}>Import a resident archive instead</a>
      </p>
    {/if}
    <p class="text-sm font-medium text-primary">Begin a resident</p>
    <h1 class="mt-1 text-3xl font-bold">Offer a beginning</h1>
    <p class="mt-2 max-w-2xl text-muted-foreground">
      A persistent resident with their own runtime, files, and memory — beginning with a seed you offer, and a gentle
      first wake.
    </p>
  </div>

  <nav class="mb-10" aria-label="Creation progress">
    <ol class="flex items-start">
      {#each steps as label, index}
        {#if index > 0}
          <div
            class="mt-4 h-0.5 min-w-4 flex-1 rounded-full transition-colors {index <= step
              ? 'bg-primary'
              : 'bg-border'}">
          </div>
        {/if}
        <li class="flex flex-col items-center gap-1.5">
          <button
            type="button"
            class="flex size-8 items-center justify-center rounded-full border-2 text-xs font-semibold transition-colors
              {index < step
              ? 'border-primary bg-primary text-primary-foreground hover:bg-primary/90'
              : index === step
                ? 'border-primary bg-background text-primary'
                : 'border-border bg-background text-muted-foreground/60'}"
            onclick={() => {
              if (index < step) step = index;
            }}
            disabled={index >= step}
            aria-label="Go to step {index + 1}: {label}"
            aria-current={index === step ? 'step' : undefined}>
            {#if index < step}
              <Check class="size-4" weight="bold" />
            {:else}
              {index + 1}
            {/if}
          </button>
          <span
            class="max-w-20 truncate px-1 text-xs {index === step
              ? 'font-semibold text-foreground'
              : 'text-muted-foreground'}">
            {label}
          </span>
        </li>
      {/each}
    </ol>
  </nav>

  {#if $form.errors.base}
    <Alert variant="destructive" class="mb-6">
      <AlertTitle>Could not create the resident</AlertTitle>
      <AlertDescription
        >{Array.isArray($form.errors.base) ? $form.errors.base.join(', ') : $form.errors.base}</AlertDescription>
    </Alert>
  {/if}

  <Card>
    {#key step}
      <div in:fly={{ y: 8, duration: 250 }}>
        {#if step === 0}
          <BeginningStep />
        {:else if step === 1}
          <AppearanceStep {form} {colour_options} {icon_options} />
        {:else if step === 2}
          <SoulSeedStep {form} bind:openBeginning />
        {:else if step === 3}
          <RuntimeStep {form} {grouped_models} bind:selectedModel />
        {:else}
          <ReviewStep
            {form}
            {grouped_models}
            {selectedModel}
            {openBeginning}
            bind:acknowledged
            onedit={() => (step = 2)} />
        {/if}
      </div>
    {/key}

    <CardFooter class="flex items-center justify-between border-t pt-6">
      <div>
        {#if step === 0}
          <Button type="button" variant="ghost" onclick={cancel}>Cancel</Button>
        {:else}
          <Button type="button" variant="outline" onclick={back}>
            <ArrowLeft class="mr-2 size-4" />
            Back
          </Button>
        {/if}
      </div>

      {#if step < steps.length - 1}
        <Button type="button" onclick={next} disabled={!canContinue}>
          {step === 0 ? 'Begin' : 'Continue'}
          <ArrowRight class="ml-2 size-4" />
        </Button>
      {:else}
        <Button type="button" onclick={createAgent} disabled={!canCreate}>
          {#if $form.processing}
            Preparing…
          {:else}
            <Check class="mr-2 size-4" />
            Create resident and commit this seed
          {/if}
        </Button>
      {/if}
    </CardFooter>
  </Card>

  <p class="mt-4 text-center text-xs text-muted-foreground">
    Your uncommitted draft is saved only in this browser until you create the resident.
  </p>
</div>
