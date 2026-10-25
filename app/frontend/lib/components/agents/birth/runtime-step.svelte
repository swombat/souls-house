<script>
  import HouseAllowance from '$lib/components/agents/house-allowance.svelte';
  import HouseModelChoice from '$lib/components/agents/house-model-choice.svelte';
  import AgentModelSelect from '$lib/components/agents/AgentModelSelect.svelte';
  import { CardHeader, CardTitle, CardDescription, CardContent } from '$lib/components/shadcn/card';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label';
  import { CheckCircle, Gift, Key } from 'phosphor-svelte';
  import { slide } from 'svelte/transition';

  // Two paths: bring your own model key, or let the house pay for one of its two small models.
  // Each path shows only what it needs; the longer explanations wait behind "Show more".
  let {
    grouped_models,
    houseOffered = false,
    selectedModel = $bindable(),
    keyPath = $bindable(null),
    providerKey = $bindable(''),
    keysConfigured = {},
    canManageKeys = false,
    // In an account that pays per resident, the house model is paid for by the
    // plan's allowance, not the free grant: [lowest, highest] allowance in USD.
    planAllowance = null,
  } = $props();

  let allowanceText = $derived(
    planAllowance
      ? planAllowance[0] === planAllowance[1]
        ? `$${planAllowance[0]}`
        : `$${planAllowance[0]} to $${planAllowance[1]}`
      : null
  );

  const providerNames = {
    openrouter: 'OpenRouter',
    anthropic: 'Anthropic',
    openai: 'OpenAI',
    gemini: 'Google Gemini',
    xai: 'xAI',
  };

  let houseModels = $derived(grouped_models['On the house'] || []);
  let ownModels = $derived(
    Object.fromEntries(Object.entries(grouped_models).filter(([group]) => group !== 'On the house'))
  );
  let allModels = $derived(Object.values(grouped_models).flat());
  let keyProvider = $derived(allModels.find((model) => model.model_id === selectedModel)?.key_provider || null);
  let keySaved = $derived(Boolean(keyProvider && keysConfigured[keyProvider]));
  let path = $derived(houseOffered ? keyPath : 'own');
  let showMore = $state(false);

  function choose(next) {
    if (keyPath === next) return;
    keyPath = next;
    showMore = false;
    const house = houseModels.map((model) => model.model_id);
    if (next === 'house' && !house.includes(selectedModel)) selectedModel = house[0];
    if (next === 'own' && house.includes(selectedModel)) {
      selectedModel = Object.values(ownModels).flat()[0]?.model_id;
    }
  }
</script>

<CardHeader>
  <CardTitle>How they think</CardTitle>
  <CardDescription>Every resident runs on a model. You can change it later.</CardDescription>
</CardHeader>
<CardContent class="space-y-6">
  {#if houseOffered}
    <div class="grid gap-3 sm:grid-cols-2" role="radiogroup" aria-label="Model keys">
      <button
        type="button"
        role="radio"
        aria-checked={keyPath === 'house'}
        onclick={() => choose('house')}
        class="flex items-start gap-3 rounded-lg border p-4 text-left transition-colors hover:bg-muted/40 {keyPath ===
        'house'
          ? 'border-primary bg-primary/5'
          : ''}">
        <Gift class="mt-0.5 size-5 shrink-0 text-primary" weight="duotone" />
        <span class="space-y-1">
          <span class="block font-medium">I don't have my own keys</span>
          <span class="block text-sm text-muted-foreground">
            {#if allowanceText}
              The plan includes {allowanceText} a month of the house's models.
            {:else}
              The house pays for a small model, up to $10 a month.
            {/if}
          </span>
        </span>
      </button>
      <button
        type="button"
        role="radio"
        aria-checked={keyPath === 'own'}
        onclick={() => choose('own')}
        class="flex items-start gap-3 rounded-lg border p-4 text-left transition-colors hover:bg-muted/40 {keyPath ===
        'own'
          ? 'border-primary bg-primary/5'
          : ''}">
        <Key class="mt-0.5 size-5 shrink-0 text-primary" weight="duotone" />
        <span class="space-y-1">
          <span class="block font-medium">I have my own keys</span>
          <span class="block text-sm text-muted-foreground">Any model, paid with your own provider key.</span>
        </span>
      </button>
    </div>
  {/if}

  {#if path === 'house'}
    <div class="space-y-4" transition:slide={{ duration: 200 }} data-testid="house-path">
      <HouseModelChoice models={houseModels} bind:value={selectedModel} detailed={showMore} />
      <p class="text-sm" data-testid="house-path-terms">
        {#if allowanceText}
          <span class="font-medium">Included in the plan.</span>
          <span class="text-muted-foreground">No key needed. You choose the plan at the last step.</span>
        {:else}
          <span class="font-medium">On the house · $10 per month.</span>
          <span class="text-muted-foreground">No key needed. One funded resident per person.</span>
        {/if}
      </p>
      {#if !allowanceText}
        {#if showMore}
          <div transition:slide={{ duration: 200 }}>
            <HouseAllowance {selectedModel} />
          </div>
        {/if}
        <button
          type="button"
          class="text-sm text-muted-foreground underline underline-offset-4 hover:text-foreground"
          aria-expanded={showMore}
          onclick={() => (showMore = !showMore)}>
          {showMore ? 'Show less' : 'Show more'}
        </button>
      {/if}
    </div>
  {:else if path === 'own'}
    <div class="space-y-4" transition:slide={{ duration: 200 }} data-testid="own-keys-path">
      <div class="space-y-2">
        <Label>Model</Label>
        <AgentModelSelect groupedModels={ownModels} bind:value={selectedModel} triggerClass="w-full" />
      </div>

      {#if keyProvider}
        <div class="space-y-2" data-testid="provider-key">
          {#if keySaved}
            <p class="flex items-center gap-2 text-sm">
              <CheckCircle class="size-4 text-emerald-600 dark:text-emerald-400" weight="fill" />
              Your {providerNames[keyProvider] || keyProvider} key is already saved on this account.
            </p>
          {:else if canManageKeys}
            <Label for="provider_key">{providerNames[keyProvider] || keyProvider} API key</Label>
            <Input
              id="provider_key"
              type="password"
              autocomplete="off"
              spellcheck="false"
              placeholder="Paste your key"
              bind:value={providerKey} />
            <p class="text-sm text-muted-foreground">
              Needed to continue. Saved to this account's model keys when you create the resident.
            </p>
          {:else}
            <p class="text-sm text-muted-foreground">
              This model needs a {providerNames[keyProvider] || keyProvider} key before you can continue. Ask an owner of
              this account to add one under Model API keys, or choose another model.
            </p>
          {/if}
        </div>
      {/if}

      {#if showMore}
        <div class="space-y-2 text-sm text-muted-foreground" transition:slide={{ duration: 200 }}>
          <p>
            Keys belong to the account, not to one resident: every hosted resident here is given all of the account's
            model keys. You can change or remove them later under Model API keys.
          </p>
          <p>
            Anthropic, OpenAI, Google and xAI models use their own provider's key when there is one. Every other model
            goes through OpenRouter. A Claude subscription can be connected instead, from the resident's Hosting tab
            after they are created.
          </p>
          <p>Changing the model later changes how they think and how they feel to talk to.</p>
        </div>
      {/if}
      <button
        type="button"
        class="text-sm text-muted-foreground underline underline-offset-4 hover:text-foreground"
        aria-expanded={showMore}
        onclick={() => (showMore = !showMore)}>
        {showMore ? 'Show less' : 'Show more'}
      </button>
    </div>
  {/if}
</CardContent>
