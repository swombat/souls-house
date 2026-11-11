<script>
  import ReviewStep from '$lib/components/agents/birth/review-step.svelte';
  import RuntimeStep from '$lib/components/agents/birth/runtime-step.svelte';
  import SoulSeedStep from '$lib/components/agents/birth/soul-seed-step.svelte';
  import AppearanceStep from '$lib/components/agents/birth/appearance-step.svelte';
  import BeginningStep from '$lib/components/agents/birth/beginning-step.svelte';
  import BirthScene from '$lib/components/agents/birth/birth-scene.svelte';
  import PlanStep from '$lib/components/agents/birth/plan-step.svelte';
  import BirthProgress from '$lib/components/agents/birth/birth-progress.svelte';
  import PaidPendingAlert from '$lib/components/agents/birth/paid-pending-alert.svelte';
  import CreateButtonLabel from '$lib/components/agents/birth/create-button-label.svelte';
  import { payForResident, payAgain, openCheckout, trialOrderState } from '$lib/paid-birth';
  import { WizardPay, draftFingerprint, isItemPayment, staleQuote } from '$lib/item-order.svelte.js';
  import { trialApplies } from '$lib/pricing';
  import { onMount } from 'svelte';
  import { fade, fly } from 'svelte/transition';
  import { useForm, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  import { Card, CardFooter } from '$lib/components/shadcn/card';
  import { Alert, AlertDescription, AlertTitle } from '$lib/components/shadcn/alert';
  import { ArrowLeft, ArrowRight } from 'phosphor-svelte';

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
  // pays for it; the resident is created only once the payment clears, or,
  // in an account with a live subscription, once the owner confirms the quote.
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
  let paidPending = $state(null);
  // The pay state: phase, error, the order kept for retries, and an item
  // order's quote waiting for the owner (see $lib/item-order.svelte.js).
  const pay = new WizardPay(finish);
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
  let paying = $derived(pay.phase !== null);
  let canCreate = $derived(
    step === lastStep &&
      formComplete &&
      acknowledged &&
      !$form.processing &&
      !atCostNeedsOwnModel &&
      !pay.itemPayment &&
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
        pay.lastPayment = draft.trial_payment;
      }
    }
    // An item order kept with a draft resumes through its payment URL: the
    // house says whether it still waits for the quote or is already accepted.
    if (draft?.item_payment?.payment_url) pay.lastPayment = draft.item_payment;
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
        trial_payment: pay.lastPayment?.order?.trial ? pay.lastPayment : null,
        item_payment: isItemPayment(pay.lastPayment) ? pay.lastPayment : null,
      })
    );
  });

  // What an item order's quote is for. An edit that changes it while the
  // quote is unsent forgets the order (an accepted one is always resumed).
  let fingerprint = $derived(
    draftFingerprint({
      tier: chosenPlan?.tier ?? tier,
      rate: chosenPlan?.rate,
      trial: free,
      agent: $form.agent,
      selectedModel,
      openBeginning,
    })
  );
  $effect(() => pay.check(fingerprint));

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
        item: isItemPayment(pay.lastPayment),
      };
      pay.phase = null;
    }
  }

  async function payAndCreate() {
    pay.error = null;
    const key = keyPath !== 'house' ? providerKey.trim() : '';
    const onPhase = (phase) => (pay.phase = phase);
    const quotedFor = fingerprint;
    const start = () =>
      payForResident({
        billing,
        agent: draftAgent(),
        tier: chosenPlan?.tier ?? tier,
        rate: chosenPlan?.rate ?? 'standard',
        trial: free,
        providerKey: key && keyProvider ? { provider: keyProvider, value: key } : null,
        onPhase,
      });
    try {
      // Once an order exists, retries resume it; only an unpaid card order
      // may be replaced by choosing a different plan.
      const retrying = pay.resumes(chosenPlan, free);
      let result = retrying ? await payAgain({ billing, payment: pay.lastPayment, onPhase }) : await start();
      // The house says a kept item order is still unsent, but it was quoted
      // for another draft: it is abandoned and a fresh one made.
      if (
        retrying &&
        result.itemQuote &&
        staleQuote({ ...result.payment, quoted_for: pay.lastPayment.quoted_for }, quotedFor)
      ) {
        pay.invalidate();
        result = await start();
      }
      // Nothing is charged until the owner confirms the quote.
      if (result.itemQuote) return pay.quoted(result.payment, quotedFor);
      if (result.checkoutUrl) {
        // The draft stays until Stripe has started the trial (see onMount).
        pay.lastPayment = result.payment;
        pay.phase = 'leaving';
        return openCheckout(result.checkoutUrl);
      }
      finish(result);
    } catch (error) {
      if (error.payment) pay.lastPayment = { ...error.payment, quoted_for: pay.lastPayment?.quoted_for };
      // A trial order the house refused to resume (its Checkout closed) is
      // replaced by a new one on the next try.
      if (pay.lastPayment?.order?.trial && error.data?.error && !error.data.order) pay.lastPayment = null;
      pay.error = error.message;
      pay.phase = null;
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
<svelte:window onpageshow={(event) => event.persisted && pay.phase === 'leaving' && (pay.phase = null)} />

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

  <BirthProgress {steps} bind:step />

  {#if vmBirthRefusal && !$form.errors.base}
    <Alert class="mb-6" data-testid="vm-birth-refusal">
      <AlertTitle>New residents can't be created right now</AlertTitle>
      <AlertDescription>{vmBirthRefusal}</AlertDescription>
    </Alert>
  {/if}

  <PaidPendingAlert pending={paidPending} />

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
            payError={pay.error}
            {trial}
            billingUrl={`/accounts/${account.id}/billing`}
            payPaid={pay.settled}
            itemPayment={pay.itemPayment}
            deferred={pay.deferred}
            onphase={(phase) => (pay.phase = phase)}
            onconfirmed={pay.confirmed}
            onconfirmfailed={pay.confirmFailed}
            ondismiss={pay.dismiss}
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
          <CreateButtonLabel
            processing={$form.processing}
            phase={pay.phase}
            {billing}
            {chosenTier}
            {free}
            name={$form.agent.name} />
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
