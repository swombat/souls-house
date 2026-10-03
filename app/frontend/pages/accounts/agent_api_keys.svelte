<script>
  import { page, router } from '@inertiajs/svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ModelKeysDeliveryNote from '$lib/components/accounts/ModelKeysDeliveryNote.svelte';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import Button from '$lib/components/shadcn/button/button.svelte';
  import { CheckCircle, XCircle } from 'phosphor-svelte';
  import { accountAgentApiKeysPath } from '@/routes';
  import AgentProviderSubscriptionPanel from '$lib/components/agents/AgentProviderSubscriptionPanel.svelte';
  import { siteName } from '$lib/branding';

  // Read as props, not once from $page.props, so a save re-renders the "Set" badges.
  let { account, ai_api_keys_configured = {}, can_manage_ai_credentials = false, subscription_agents = [] } = $props();
  const providerSections = [
    {
      title: 'OpenRouter',
      description:
        'OpenRouter usage is billed through its API rather than a model provider subscription. For supported direct-provider models, a selected subscription or matching provider key takes priority. Models without a supported direct route stay on OpenRouter.',
      providers: [
        {
          id: 'openrouter',
          name: 'OpenRouter API key',
          help: 'Also available to residents for ancillary services such as image generation.',
        },
      ],
    },
    {
      title: 'API Key or Claude-Code Clamped subscription',
      description:
        'Use a metered Anthropic API key, or connect a hosted Claude resident to a personal Claude subscription from that resident’s Hosting tab.',
      detailsLabel: 'How Claude Code clamping works',
      details:
        'When clamping is selected, Chaos runs the resident through Claude Code inside its hosted runtime instead of sending requests with the Anthropic API key. The Claude sign-in stays in that resident’s private state volume, usage draws from the connected Claude plan, and requests fail rather than falling back to metered API billing if the subscription is unavailable.',
      providers: [
        {
          id: 'anthropic',
          name: 'Anthropic API key',
          help: 'Enter a metered Anthropic API key here, or configure Claude Code clamping in the resident’s Hosting tab.',
        },
      ],
    },
    {
      title: 'API key or experimental Antigravity clamp',
      description:
        'Use a metered Gemini API key, or explicitly opt a hosted Gemini resident into the official Antigravity CLI transport.',
      detailsLabel: 'Google policy and account risk',
      details:
        'Google’s current Antigravity terms prohibit third-party access patterns and Google has enforced against accounts using third-party tools or proxies. Running the official Antigravity CLI as a Chaos subprocess keeps OAuth credentials out of souls.house, but does not make this workflow supported or terms-compliant. Use an account you can risk losing access to related Gemini developer services.',
      providers: [
        {
          id: 'gemini',
          name: 'Gemini',
          help: 'Enter a metered Gemini API key here, or configure experimental Antigravity clamping in the resident’s Hosting tab.',
        },
      ],
    },
    {
      title: 'API key or subscription',
      description:
        'These providers can use a metered API key entered here, or a resident can be connected to a supported subscription through Chaos.',
      providers: [
        {
          id: 'openai',
          name: 'OpenAI',
          help: 'Use an OpenAI API key here, or connect the resident to a ChatGPT subscription in Chaos.',
        },
        {
          id: 'xai',
          name: 'xAI',
          help: 'Use an xAI API key here, or connect the resident to an eligible xAI subscription in Chaos.',
        },
      ],
    },
    {
      title: 'Subscription API keys',
      description:
        'Enter the special API key issued by the provider for its coding subscription, or an ordinary metered API key.',
      details:
        'Z.ai, Moonshot, and MiniMax coding plans expose a dedicated API endpoint and issue a special key for it. The key is passed to Chaos like any other API key, but usage draws from the subscription allowance when the resident uses the matching subscription provider configuration. An ordinary API key continues to incur metered API charges.',
      providers: [
        {
          id: 'zai',
          name: 'Z.ai (GLM)',
          help: 'Accepts a GLM Coding Plan key or a standard Z.ai API key.',
        },
        {
          id: 'moonshot',
          name: 'Moonshot (Kimi)',
          help: 'Accepts a Kimi coding subscription key or a standard Moonshot API key.',
        },
        {
          id: 'minimax',
          name: 'MiniMax',
          help: 'Accepts a MiniMax coding subscription key or a standard API key.',
        },
      ],
    },
  ];
  const aiProviders = providerSections.flatMap((section) => section.providers);

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
  <title>Model API keys · {account.name}</title>
</svelte:head>

<AccountSettingsLayout
  {account}
  active="model_api_keys"
  title="Model API keys"
  description="The AI provider keys residents in this account use to call models.">
  <FlashMessages flash={$page.props.flash} />

  <form onsubmit={save} class="space-y-4">
    <div class="space-y-4">
      <ModelKeysDeliveryNote accountName={account.name} />

      <div class="space-y-6">
        {#each providerSections as section}
          <section class="space-y-3 rounded-lg border p-4">
            <div class="space-y-1">
              <h2 class="font-medium">{section.title}</h2>
              <p class="text-sm text-muted-foreground">{section.description}</p>
            </div>

            {#if section.details}
              <details class="rounded-md bg-muted/50 px-3 py-2 text-sm">
                <summary class="cursor-pointer font-medium">
                  {section.detailsLabel || 'How subscription API keys work'}
                </summary>
                <p class="mt-2 text-muted-foreground">{section.details}</p>
              </details>
            {/if}

            <div class="grid gap-4 md:grid-cols-2">
              {#each section.providers as provider}
                <div class="space-y-2">
                  <div class="flex items-center justify-between gap-2">
                    <Label for={`${provider.id}_api_key`}>{provider.name}</Label>
                    <div class="flex items-center gap-2">
                      {#if ai_api_keys_configured[provider.id] && !clearedAiApiKeys.includes(provider.id)}
                        <span
                          class="flex items-center gap-1 text-xs font-medium text-emerald-600 dark:text-emerald-400">
                          <CheckCircle size={16} weight="fill" />
                          Set
                        </span>
                        {#if can_manage_ai_credentials}
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            onclick={() => toggleApiKeyRemoval(provider.id)}>
                            Remove
                          </Button>
                        {/if}
                      {:else}
                        <span class="flex items-center gap-1 text-xs font-medium text-muted-foreground">
                          <XCircle size={16} weight="fill" />
                          {clearedAiApiKeys.includes(provider.id) ? 'Will be removed' : 'Not set'}
                        </span>
                        {#if can_manage_ai_credentials && clearedAiApiKeys.includes(provider.id)}
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            onclick={() => toggleApiKeyRemoval(provider.id)}>
                            Undo
                          </Button>
                        {/if}
                      {/if}
                    </div>
                  </div>
                  <Input
                    id={`${provider.id}_api_key`}
                    type="password"
                    autocomplete="off"
                    bind:value={aiApiKeys[provider.id]}
                    disabled={!can_manage_ai_credentials || clearedAiApiKeys.includes(provider.id)}
                    placeholder={ai_api_keys_configured[provider.id] ? 'Enter a replacement key' : 'Enter API key'} />
                  <p class="text-xs text-muted-foreground">{provider.help}</p>
                </div>
              {/each}
            </div>
          </section>
        {/each}
      </div>

      <section class="space-y-4 rounded-lg border p-4">
        <div class="space-y-1">
          <h2 class="font-medium">Provider subscription accounts</h2>
          <p class="text-sm text-muted-foreground">
            Connect a personal provider subscription to a specific resident. The sign-in happens inside that resident's
            Chaos container; {$siteName} never receives or stores the provider token.
          </p>
        </div>

        {#if subscription_agents.length === 0}
          <p class="text-sm text-muted-foreground">
            No residents currently use a provider with supported subscription sign-in.
          </p>
        {:else}
          <div class="space-y-3">
            {#each subscription_agents as subscriptionAgent (subscriptionAgent.id)}
              <AgentProviderSubscriptionPanel {account} {subscriptionAgent} canManage={can_manage_ai_credentials} />
            {/each}
          </div>
        {/if}

        <p class="text-xs text-muted-foreground">
          Claude subscriptions use Claude Code clamping. Experimental Gemini subscription access uses Google’s official
          Antigravity CLI while Chaos retains tool and permission control.
        </p>
      </section>

      {#if account.use_system_ai_credentials}
        <div class="rounded-md border border-blue-500/30 bg-blue-500/10 p-4">
          <div class="space-y-1">
            <p class="text-sm font-medium">Shared AI keys are available as a fallback</p>
            <p class="text-sm text-muted-foreground">
              A site administrator has enabled shared application keys for providers where this account has no key of
              its own. Only a site administrator can change this setting.
            </p>
          </div>
        </div>
      {/if}

      {#if !can_manage_ai_credentials}
        <p class="text-sm text-muted-foreground">Only account owners and administrators can change model API keys.</p>
      {/if}
    </div>

    {#if can_manage_ai_credentials}
      <div class="flex justify-end">
        <Button type="submit" disabled={saving}>{saving ? 'Saving…' : 'Save model API keys'}</Button>
      </div>
    {/if}
  </form>
</AccountSettingsLayout>
