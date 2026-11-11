<script>
  import ReviewStep from '$lib/components/agents/birth/review-step.svelte';
  import RuntimeStep from '$lib/components/agents/birth/runtime-step.svelte';
  import SoulSeedStep from '$lib/components/agents/birth/soul-seed-step.svelte';
  import AppearanceStep from '$lib/components/agents/birth/appearance-step.svelte';
  import BeginningStep from '$lib/components/agents/birth/beginning-step.svelte';
  import BirthScene from '$lib/components/agents/birth/birth-scene.svelte';
  import PlanStep from '$lib/components/agents/birth/plan-step.svelte';
  import { payForResident, payAgain, openCheckout, trialOrderState } from '$lib/paid-birth';
  import { trialApplies, usd } from '$lib/pricing';
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
    // The account's free 14 days: { eligible, days }.
    trial = null,
  } = $props();

  const draftKey = `helixkit:agent-birth-draft:${account.id}`;
  // In an account that pays per resident, a sixth step chooses the size and
  // pays for it; the resident is created only once the payment clears.
  const steps = billing
    ? ['Welcome', 'Appearance', 'Soul seed', 'Runtime', 'Review', 'Plan']
    : ['Welcome', 'Appearance', 'Soul seed', 'Runtime', 'Review'];
  const captions = [
    billing ? 'Six small steps, a few minutes.' : 'Five small steps, a few minutes.',
    'A name and a colour to start with. Both can change later.',
    'A few words for them to grow from.',
    'The model they think with.',
    billing ? 'Look it over before choosing their size.' : 'Everything is ready when you are.',
    'Their size, and how it is paid.',
  ];
  const reviewStep = 4;
  const lastStep = steps.length - 1;

  let tier = $state(null);
  let paymentMethod = $state(billing?.payment_method || null);
  let payPhase = $state(null);
  let payError = $state(null);
  let lastPayment = $state(null);
  let paidPending = $state(null);
  // An item order (the resident is added to the account's existing Stripe
  // subscription, nothing charged today) waiting for the owner to read its quote.
  let itemPayment = $state(null);
  const isItemPayment = (payment) => Boolean(payment && (payment.order?.kind === 'item' || payment.item_quote));
  let deferred = $derived(isItemPayment(lastPayment));
  // The plans on offer: offers (a tier at a rate) when the server sends
  // them, else the standard tiers.
  let planOptions = $derived(billing?.offers?.length ? billing.offers : billing?.tiers || []);
  let planAllowance = $derived(
    planOptions.length
      ? [
          Math.min(...planOptions.map((option) => option.allowance_usd)),
          Math.max(...planOptions.map((option) => option.allowance_usd)),
        ]
      : null
  );
  let chosenTier = $derived(planOptions.find((candidate) => candidate.id === tier) || null);
  // The free 14 days ask for no card: Stripe's Checkout starts them.
  let free = $derived(trialApplies(trial, chosenTier));
  let chosenPlan = $derived(
    chosenTier ? { tier: chosenTier.tier ?? chosenTier.id, rate: chosenTier.rate ?? 'standard' } : null
  );
  // At cost includes no house model: a draft on a house-funded model can't
  // be paid for at cost (the server refuses it too).
  let atCostNeedsOwnModel = $derived(
    chosenPlan?.rate === 'at_cost' &&
      (grouped_models['On the house'] || []).some((model) => model.model_id === selectedModel)
  );

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
      !atCostNeedsOwnModel &&
      !itemPayment &&
      (!billing ||
        (billing.can_pay && Boolean(chosenTier) && (free || Boolean(paymentMethod)) && !paying && !paidPending))
  );

  onMount(async () => {
    let draft = null;
    try {
      draft = JSON.parse(localStorage.getItem(draftKey) || 'null');
    } catch {
      localStorage.removeItem(draftKey);
    }
    // A draft that went to Stripe for its free trial is spent once the trial
    // has started; one whose Checkout is still open resumes it.
    if (draft?.trial_payment) {
      const state = await trialOrderState(draft.trial_payment);
      if (state === 'done') {
        localStorage.removeItem(draftKey);
        draft = null;
      } else if (state === 'open') {
        lastPayment = draft.trial_payment;
      }
    }
    // An item order kept with a draft resumes through its payment URL: the
    // house says whether it still waits for the quote or is already accepted.
    if (draft?.item_payment?.payment_url) lastPayment = draft.item_payment;
    if (draft) {
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
        trial_payment: lastPayment?.order?.trial ? lastPayment : null,
        item_payment: isItemPayment(lastPayment) ? lastPayment : null,
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

  // A resident born, or still being confirmed. Shared by the card path and
  // the item path (confirmed from the quote panel).
  function finish(result) {
    localStorage.removeItem(draftKey);
    if (result.redirectTo) {
      router.visit(result.redirectTo);
    } else {
      paidPending = {
        ...(result.order || { resident_name: $form.agent.name }),
        item: isItemPayment(lastPayment),
      };
      payPhase = null;
    }
  }

  function itemConfirmed(result) {
    itemPayment = null;
    finish(result);
  }

  function itemConfirmFailed(error) {
    if (error.payment) lastPayment = error.payment;
    payPhase = null;
    // A changed price is shown by the panel itself, with the new quote.
    if (error.itemQuote) {
      payError = null;
      return;
    }
    // Anything else resumes through the order's payment URL.
    itemPayment = null;
    payError = error.message;
  }

  async function payAndCreate() {
    payError = null;
    const key = keyPath !== 'house' ? providerKey.trim() : '';
    const onPhase = (phase) => (payPhase = phase);
    try {
      // Once an order exists, retries resume it; only an unpaid one may be
      // replaced by choosing a different plan.
      const retrying =
        lastPayment &&
        (lastPayment.paid ||
          lastPayment.accepted ||
          (lastPayment.order?.tier === chosenPlan?.tier &&
            (lastPayment.order?.rate ?? 'standard') === chosenPlan?.rate &&
            Boolean(lastPayment.order?.trial) === free));
      const result = retrying
        ? await payAgain({ billing, payment: lastPayment, onPhase })
        : await payForResident({
            billing,
            agent: draftAgent(),
            tier: chosenPlan?.tier ?? tier,
            rate: chosenPlan?.rate ?? 'standard',
            trial: free,
            providerKey: key && keyProvider ? { provider: keyProvider, value: key } : null,
            onPhase,
          });
      if (result.itemQuote) {
        // Nothing is charged until the owner confirms the quote.
        lastPayment = result.payment;
        itemPayment = result.payment;
        payPhase = null;
        return;
      }
      if (result.checkoutUrl) {
        // The draft stays until Stripe has started the trial (see onMount).
        lastPayment = result.payment;
        payPhase = 'leaving';
        return openCheckout(result.checkoutUrl);
      }
      finish(result);
    } catch (error) {
      if (error.payment) lastPayment = error.payment;
      // A trial order the house refused to resume (its Checkout closed) is
      // replaced by a new one on the next try.
      if (lastPayment?.order?.trial && error.data?.error && !error.data.order) lastPayment = null;
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

<!-- Back from Stripe's Checkout through the browser's history: the button works again. -->
<svelte:window onpageshow={(event) => event.persisted && payPhase === 'leaving' && (payPhase = null)} />

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
      <AlertTitle>
        {paidPending.item ? "On the account's bill" : paidPending.trial ? 'Free trial started' : 'Payment received'}
      </AlertTitle>
      <AlertDescription>
        {#if paidPending.item}
          {paidPending.resident_name || 'Your resident'} is on the account's bill and is being created; it will appear with
          your residents in a moment.
        {:else}
          Stripe is still confirming it. {paidPending.resident_name || 'Your resident'} will be created as soon as it does,
          and will appear with your residents. You can leave this page.
        {/if}
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
            bind:providerKey
            {planAllowance} />
        {:else if step === reviewStep}
          <ReviewStep
            {form}
            {grouped_models}
            {selectedModel}
            {openBeginning}
            bind:acknowledged
            onedit={() => (step = 2)} />
        {:else}
          <PlanStep
            {billing}
            residentName={$form.agent.name}
            bind:tier
            bind:paymentMethod
            {payError}
            {trial}
            billingUrl={`/accounts/${account.id}/billing`}
            payPaid={Boolean(lastPayment?.paid || lastPayment?.accepted)}
            {itemPayment}
            {deferred}
            onphase={(phase) => (payPhase = phase)}
            onconfirmed={itemConfirmed}
            onconfirmfailed={itemConfirmFailed}
            ondismiss={() => (itemPayment = null)}
            blocked={atCostNeedsOwnModel
              ? `At cost includes no house model, and ${$form.agent.name || 'this resident'} is set to think on the house. Go back to the model step and connect a subscription or key, or choose the standard price.`
              : null}
            busy={paying} />
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
            Starting…
          {:else if payPhase === 'leaving'}
            Opening Stripe…
          {:else if payPhase === 'adding'}
            Adding to the bill…
          {:else if payPhase === 'paying'}
            Confirming payment…
          {:else if payPhase === 'confirming'}
            Preparing {$form.agent.name}…
          {:else if billing && chosenTier && free}
            <Check class="mr-2 size-4" />
            Start free
          {:else if billing && chosenTier}
            <Check class="mr-2 size-4" />
            Create {$form.agent.name} · {usd(chosenTier.monthly_usd)} a month + VAT
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
