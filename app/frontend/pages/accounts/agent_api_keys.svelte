<script>
  import { Link, page, router } from '@inertiajs/svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ModelKeysDeliveryNote from '$lib/components/accounts/ModelKeysDeliveryNote.svelte';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import Button from '$lib/components/shadcn/button/button.svelte';
  import { CheckCircle, XCircle } from 'phosphor-svelte';
  import { accountAgentApiKeysPath, accountAgentsPath, editAccountAgentPath } from '@/routes';

  // Read as props, not once from $page.props, so a save re-renders the "Set" badges.
  let { account, ai_api_keys_configured = {}, can_manage_ai_credentials = false, residents = [] } = $props();

  const openRouterProvider = {
    id: 'openrouter',
    name: 'OpenRouter API key',
  };

  const fallbackProviders = [
    { id: 'anthropic', name: 'Anthropic' },
    { id: 'gemini', name: 'Gemini' },
    { id: 'openai', name: 'OpenAI' },
    { id: 'xai', name: 'xAI' },
    { id: 'zai', name: 'Z.ai' },
    {
      id: 'moonshot',
      name: 'Kimi Code',
      note: 'Use a Kimi Code Console key only. Standard Moonshot platform (PAYG) keys do not work here.',
    },
    { id: 'minimax', name: 'MiniMax' },
  ];

  const aiProviders = [openRouterProvider, ...fallbackProviders];

  let aiApiKeys = $state(Object.fromEntries(aiProviders.map((provider) => [provider.id, ''])));
  let clearedAiApiKeys = $state([]);

  function getFormData() {
    const accountData = {
      clear_ai_api_keys: clearedAiApiKeys,
    };

    for (const provider of aiProviders) {
      const value = aiApiKeys[provider.id]?.trim();
      if (value) accountData[`${provider.id}_api_key`] = value;
    }

    return { account: accountData };
  }

  let saving = $state(false);

  function save(event) {
    event.preventDefault();
    if (saving) return;

    saving = true;
    router.put(accountAgentApiKeysPath(account.id), getFormData(), {
      preserveScroll: true,
      onSuccess: () => {
        aiApiKeys = Object.fromEntries(aiProviders.map((provider) => [provider.id, '']));
        clearedAiApiKeys = [];
      },
      onFinish: () => (saving = false),
    });
  }

  function toggleApiKeyRemoval(providerId) {
    clearedAiApiKeys = clearedAiApiKeys.includes(providerId)
      ? clearedAiApiKeys.filter((id) => id !== providerId)
      : [...clearedAiApiKeys, providerId];
    aiApiKeys[providerId] = '';
  }
</script>

<svelte:head>
  <title>Model keys · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="model_api_keys"
  title="Model keys"
  description="General and fallback API keys shared by residents in this account.">
  <FlashMessages flash={$page.props.flash} />

  <form onsubmit={save} class="space-y-6">
    <section class="space-y-3 rounded-lg border p-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="space-y-1">
          <div class="flex items-center gap-2">
            <h2 class="font-medium">OpenRouter</h2>
            <span
              class="rounded-full bg-emerald-500/15 px-2 py-0.5 text-xs font-medium text-emerald-700 dark:text-emerald-300">
              Recommended
            </span>
          </div>
          <p class="text-sm text-muted-foreground">
            Covers image generation and any model without a direct provider key.
          </p>
        </div>

        <div class="flex items-center gap-2">
          {#if ai_api_keys_configured.openrouter && !clearedAiApiKeys.includes('openrouter')}
            <span class="flex items-center gap-1 text-xs font-medium text-emerald-600 dark:text-emerald-400">
              <CheckCircle size={16} weight="fill" />
              Set
            </span>
            {#if can_manage_ai_credentials}
              <Button type="button" variant="ghost" size="sm" onclick={() => toggleApiKeyRemoval('openrouter')}>
                Remove
              </Button>
            {/if}
          {:else}
            <span class="flex items-center gap-1 text-xs font-medium text-muted-foreground">
              <XCircle size={16} weight="fill" />
              {clearedAiApiKeys.includes('openrouter') ? 'Will be removed' : 'Not set'}
            </span>
            {#if can_manage_ai_credentials && clearedAiApiKeys.includes('openrouter')}
              <Button type="button" variant="ghost" size="sm" onclick={() => toggleApiKeyRemoval('openrouter')}>
                Undo
              </Button>
            {/if}
          {/if}
        </div>
      </div>

      <div class="space-y-1.5">
        <Label for="openrouter_api_key" class="sr-only">OpenRouter API key</Label>
        <Input
          id="openrouter_api_key"
          type="password"
          autocomplete="off"
          bind:value={aiApiKeys.openrouter}
          disabled={!can_manage_ai_credentials || clearedAiApiKeys.includes('openrouter')}
          placeholder={ai_api_keys_configured.openrouter ? 'Enter a replacement key' : 'Enter API key'} />
      </div>
    </section>

    <section class="rounded-lg border">
      <div class="border-b px-4 py-3">
        <h2 class="font-medium">Fallback provider keys</h2>
        <p class="text-sm text-muted-foreground">
          Direct provider keys used when a resident is not using a personal subscription.
        </p>
      </div>

      <div class="divide-y">
        {#each fallbackProviders as provider (provider.id)}
          <div class="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:gap-4">
            <div class="flex items-center justify-between gap-2 sm:w-44 sm:shrink-0 sm:pt-2">
              <Label for={`${provider.id}_api_key`} class="font-medium">{provider.name}</Label>
              {#if ai_api_keys_configured[provider.id] && !clearedAiApiKeys.includes(provider.id)}
                <span class="flex items-center gap-1 text-xs font-medium text-emerald-600 dark:text-emerald-400">
                  <CheckCircle size={15} weight="fill" />
                  Set
                </span>
              {:else}
                <span class="flex items-center gap-1 text-xs font-medium text-muted-foreground">
                  <XCircle size={15} weight="fill" />
                  {clearedAiApiKeys.includes(provider.id) ? 'Will be removed' : 'Not set'}
                </span>
              {/if}
            </div>

            <div class="flex-1 min-w-0 space-y-1">
              <div class="flex items-center gap-2">
                <Input
                  id={`${provider.id}_api_key`}
                  type="password"
                  autocomplete="off"
                  bind:value={aiApiKeys[provider.id]}
                  disabled={!can_manage_ai_credentials || clearedAiApiKeys.includes(provider.id)}
                  placeholder={ai_api_keys_configured[provider.id] ? 'Enter a replacement key' : 'Enter API key'} />
                {#if can_manage_ai_credentials && ai_api_keys_configured[provider.id] && !clearedAiApiKeys.includes(provider.id)}
                  <Button type="button" variant="ghost" size="sm" onclick={() => toggleApiKeyRemoval(provider.id)}>
                    Remove
                  </Button>
                {:else if can_manage_ai_credentials && clearedAiApiKeys.includes(provider.id)}
                  <Button type="button" variant="ghost" size="sm" onclick={() => toggleApiKeyRemoval(provider.id)}>
                    Undo
                  </Button>
                {/if}
              </div>
              {#if provider.note}
                <p class="text-xs text-muted-foreground">{provider.note}</p>
              {/if}
            </div>
          </div>
        {/each}
      </div>
    </section>

    <p class="text-sm text-muted-foreground">
      {#if residents.length > 0}
        Provider subscriptions are connected on each resident's own settings:
        {#each residents as resident, index (resident.id)}
          {#if index > 0},
          {/if}<Link
            href={editAccountAgentPath(account.id, resident.id, { tab: 'settings' })}
            class="underline underline-offset-4 hover:text-foreground">{resident.name}</Link
          >{/each}.
      {:else}
        Provider subscriptions are connected
        <Link href={accountAgentsPath(account.id)} class="underline underline-offset-4 hover:text-foreground"
          >on each resident's own settings</Link
        >.
      {/if}
    </p>

    <ModelKeysDeliveryNote accountName={account.name} />

    {#if account.use_system_ai_credentials}
      <div class="rounded-md border border-blue-500/30 bg-blue-500/10 p-4">
        <div class="space-y-1">
          <p class="text-sm font-medium">Shared AI keys are available as a fallback</p>
          <p class="text-sm text-muted-foreground">
            A site administrator has enabled shared application keys for providers where this account has no key of its
            own. Only a site administrator can change this setting.
          </p>
        </div>
      </div>
    {/if}

    {#if !can_manage_ai_credentials}
      <p class="text-sm text-muted-foreground">Only account owners and administrators can change model API keys.</p>
    {/if}

    {#if can_manage_ai_credentials}
      <div class="flex justify-end">
        <Button type="submit" disabled={saving}>{saving ? 'Saving…' : 'Save model API keys'}</Button>
      </div>
    {/if}
  </form>
</AccountSettingsLayout>
