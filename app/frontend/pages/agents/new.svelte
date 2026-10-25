<script>
  import ReviewStep from '$lib/components/agents/birth/review-step.svelte';
  import RuntimeStep from '$lib/components/agents/birth/runtime-step.svelte';
  import SoulSeedStep from '$lib/components/agents/birth/soul-seed-step.svelte';
  import AppearanceStep from '$lib/components/agents/birth/appearance-step.svelte';
  import BeginningStep from '$lib/components/agents/birth/beginning-step.svelte';
  import BirthScene from '$lib/components/agents/birth/birth-scene.svelte';
  import PlanStep from '$lib/components/agents/birth/plan-step.svelte';
  import { payForResident, payAgain } from '$lib/paid-birth';
  import { onMount } from 'svelte';
  import { fade, fly } from 'svelte/transition';
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
    vm_birth_refusal: vmBirthRefusal = null,
    ai_api_keys_configured: keysConfigured = {},
    can_manage_ai_credentials: canManageKeys = false,
    billing = null,
  } = $props();

  const draftKey = `helixkit:agent-birth-draft:${account.id}`;
  // In an account that pays per resident, a sixth step chooses the plan and
  // pays for it; the resident is created only once the payment clears.
  const steps = billing
    ? ['Welcome', 'Appearance', 'Soul seed', 'Runtime', 'Review', 'Plan']
    : ['Welcome', 'Appearance', 'Soul seed', 'Runtime', 'Review'];
  const captions = [
    billing ? 'Six small steps, a few minutes.' : 'Five small steps, a few minutes.',
    'A name and a colour to start with. Both can change later.',
    'A few words for them to grow from.',
    'The model they think with.',
    billing ? 'Look it over before choosing their plan.' : 'Everything is ready when you are.',
    'Their plan, and how it is paid.',
  ];
  const reviewStep = 4;
  const lastStep = steps.length - 1;

  let tier = $state(null);
  let paymentMethod = $state(billing?.payment_method || null);
  let payPhase = $state(null);
  let payError = $state(null);
  let lastPayment = $state(null);
  let paidPending = $state(null);
  let chosenTier = $derived(billing?.tiers?.find((candidate) => candidate.id === tier) || null);

  let step = $state(0);
  let selectedModel = $state(default_model_id);
  let houseOffered = $derived(
    (grouped_models['On the house'] || []).some((model) => model.model_id === default_model_id)
  );
  let keyPath = $state(null);
  let providerKey = $state('');
  let openBeginning = $state(false);
  let acknowledged = $state(false);
  let draftReady = $state(false);
  let importOpen = $state(false);
  let hasImport = $derived(Boolean(githubResidentImportUrl || residentImportUrl));

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

  // On the own-keys path the chosen model's key must be there: already on the account, or pasted here.
  let keyProvider = $derived(
    Object.values(grouped_models)
      .flat()
      .find((model) => model.model_id === selectedModel)?.key_provider || null
  );
  let ownKeyReady = $derived(
    (houseOffered && keyPath !== 'own') ||
      !keyProvider ||
      Boolean(keysConfigured[keyProvider]) ||
      providerKey.trim().length > 0
  );

  let formComplete = $derived(
    $form.agent.name.trim().length > 0 &&
      ($form.agent.system_prompt.trim().length > 0 || openBeginning) &&
      selectedModel &&
      ownKeyReady
  );
  let canContinue = $derived(
    step === 0 ||
      (step === 1 && $form.agent.name.trim().length > 0) ||
      (step === 2 && ($form.agent.system_prompt.trim().length > 0 || openBeginning)) ||
      (step === 3 && Boolean(selectedModel) && (!houseOffered || keyPath !== null) && ownKeyReady) ||
      (step === reviewStep && Boolean(billing) && formComplete && acknowledged)
  );
  let paying = $derived(payPhase !== null);
  let canCreate = $derived(
    step === lastStep &&
      formComplete &&
      acknowledged &&
      !$form.processing &&
      (!billing || (billing.can_pay && Boolean(chosenTier) && Boolean(paymentMethod) && !paying && !paidPending))
  );

  onMount(() => {
    const saved = localStorage.getItem(draftKey);
    if (saved) {
      try {
        const draft = JSON.parse(saved);
        $form.agent.name = draft.name || '';
        $form.agent.system_prompt = draft.system_prompt || '';
        $form.agent.colour = draft.colour || null;
        $form.agent.icon = draft.icon || null;
        selectedModel = draft.model_id || default_model_id;
        keyPath = draft.key_path === 'house' || draft.key_path === 'own' ? draft.key_path : null;
        openBeginning = draft.open_beginning === true;
        $form.agent.open_beginning = openBeginning;
        // A draft never reopens past Review: the seed is acknowledged afresh each visit.
        step = Math.min(Math.max(draft.step || 0, 0), reviewStep);
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
        key_path: keyPath,
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

  function draftAgent() {
    return {
      ...$form.agent,
      model_id: selectedModel,
      open_beginning: openBeginning,
      system_prompt: openBeginning ? '' : $form.agent.system_prompt,
      scheduled_wakes_enabled: true,
    };
  }

  async function payAndCreate() {
    payError = null;
    const key = keyPath !== 'house' ? providerKey.trim() : '';
    const onPhase = (phase) => (payPhase = phase);
    try {
      const retrying = lastPayment && lastPayment.order?.tier === tier;
      const result = retrying
        ? await payAgain({ billing, payment: lastPayment, onPhase })
        : await payForResident({
            billing,
            agent: draftAgent(),
            tier,
            providerKey: key && keyProvider ? { provider: keyProvider, value: key } : null,
            onPhase,
          });
      localStorage.removeItem(draftKey);
      if (result.redirectTo) {
        router.visit(result.redirectTo);
      } else {
        paidPending = result.order || { resident_name: $form.agent.name };
        payPhase = null;
      }
    } catch (error) {
      if (error.payment) lastPayment = error.payment;
      payError = error.message;
      payPhase = null;
    }
  }

  function createAgent() {
    if (!canCreate) return;
    if (billing) return payAndCreate();

    $form.agent.model_id = selectedModel;
    $form.agent.open_beginning = openBeginning;
    if (openBeginning) $form.agent.system_prompt = '';
    // The heartbeat is on for every new resident; it can be tuned with them later.
    $form.agent.scheduled_wakes_enabled = true;
    const key = keyPath !== 'house' ? providerKey.trim() : '';
    $form.transform((data) =>
      key && keyProvider ? { ...data, provider_key: { provider: keyProvider, value: key } } : data
    );
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
  <title>A new resident</title>
</svelte:head>

<div class="mx-auto max-w-4xl px-4 py-8 sm:px-8">
  <header class="mb-8 text-center">
    <BirthScene {step} colour={$form.agent.colour} processing={$form.processing} />
    <h1 class="mt-2 text-3xl font-bold">A new resident</h1>
    <div class="mt-2 grid">
      {#key step}
        <p
          class="text-muted-foreground [grid-area:1/1]"
          in:fade={{ duration: 300, delay: 150 }}
          out:fade={{ duration: 150 }}>
          {captions[step]}
        </p>
      {/key}
    </div>
  </header>

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

  {#if vmBirthRefusal && !$form.errors.base}
    <Alert class="mb-6" data-testid="vm-birth-refusal">
      <AlertTitle>New residents can't be created right now</AlertTitle>
      <AlertDescription>{vmBirthRefusal}</AlertDescription>
    </Alert>
  {/if}

  {#if paidPending}
    <Alert class="mb-6" data-testid="paid-pending">
      <AlertTitle>Payment received</AlertTitle>
      <AlertDescription>
        Stripe is still confirming it. {paidPending.resident_name || 'Your resident'} will be created as soon as it does,
        and will appear with your residents. You can leave this page.
      </AlertDescription>
    </Alert>
  {/if}

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
          <RuntimeStep
            {grouped_models}
            {houseOffered}
            {keysConfigured}
            {canManageKeys}
            bind:selectedModel
            bind:keyPath
            bind:providerKey />
        {:else if step === reviewStep}
          <ReviewStep
            {form}
            {grouped_models}
            {selectedModel}
            {openBeginning}
            bind:acknowledged
            onedit={() => (step = 2)} />
        {:else}
          <PlanStep {billing} residentName={$form.agent.name} bind:tier bind:paymentMethod {payError} busy={paying} />
        {/if}
      </div>
    {/key}

    <CardFooter class="flex items-center justify-between border-t pt-6">
      <div>
        {#if step === 0}
          <Button type="button" variant="ghost" onclick={cancel}>Cancel</Button>
        {:else}
          <Button type="button" variant="outline" onclick={back} disabled={paying}>
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
          {:else if payPhase === 'starting'}
            Starting the plan…
          {:else if payPhase === 'paying'}
            Confirming payment…
          {:else if payPhase === 'confirming'}
            Preparing {$form.agent.name}…
          {:else if billing && chosenTier}
            <Check class="mr-2 size-4" />
            Create {$form.agent.name} · ${chosenTier.monthly_usd}/month + VAT
          {:else}
            <Check class="mr-2 size-4" />
            Create resident and commit this seed
          {/if}
        </Button>
      {/if}
    </CardFooter>
  </Card>

  {#if hasImport}
    <div class="mt-6 text-center text-sm" data-testid="resident-import-options">
      <button
        type="button"
        class="text-muted-foreground underline underline-offset-4 transition-colors hover:text-foreground"
        aria-expanded={importOpen}
        aria-controls="resident-import-choices"
        onclick={() => (importOpen = !importOpen)}>
        Import a resident instead
      </button>
      {#if importOpen}
        <div
          id="resident-import-choices"
          class="mt-3 flex flex-col items-center gap-2 sm:flex-row sm:justify-center sm:gap-6">
          {#if githubResidentImportUrl}
            <a class="text-primary underline underline-offset-4" href={githubResidentImportUrl}
              >Bring an existing GitHub resident</a>
          {/if}
          {#if residentImportUrl}
            <a class="text-primary underline underline-offset-4" href={residentImportUrl}>Import a resident archive</a>
          {/if}
        </div>
      {/if}
    </div>
  {/if}

  <p class="mt-6 text-center text-xs text-muted-foreground">
    Your draft is saved only in this browser until you create the resident.
  </p>
</div>
