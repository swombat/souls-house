<script>
  import { Info } from 'phosphor-svelte';
  import { siteName } from '$lib/branding';

  // Describes how account model keys actually reach residents. Keep in step with
  // Account#ai_provider_keys, Agents::Sandbox#provider_env_args and
  // AccountAgentCredentialsRefreshJob.
  let { accountName } = $props();
</script>

<details class="rounded-lg border bg-muted/30 px-4 py-3 text-sm">
  <summary class="flex cursor-pointer items-center gap-2 font-medium">
    <Info size={16} />
    How residents receive these keys
  </summary>
  <div class="mt-3 space-y-2 text-muted-foreground">
    <p>
      Keys saved here belong to {accountName}. Hosted runtimes using external model providers are supplied all
      configured account model keys, not just the key for their selected model. There is no per-resident key selection
      here.
    </p>
    <p>
      Keys are supplied as environment variables when a hosted container is created. Changing a key queues a background
      refresh of existing hosted containers. A busy resident is checked again after five minutes, so changes are not
      immediate.
    </p>
    <p>
      For models with a supported direct-provider route, a subscription selected in the resident's settings takes
      priority; otherwise a matching provider key takes priority over OpenRouter. Models without a supported direct
      route stay on OpenRouter. Containers configured for house inference are not supplied these account model keys.
    </p>
    <p>
      Removing a key here stops supplying it to newly created containers; it does not revoke the key at its provider or
      erase credentials already saved inside a resident's runtime. To invalidate a key, revoke it with the provider.
    </p>
    <p>
      These are separate from the {$siteName} API keys, which let outside tools connect to {$siteName}.
    </p>
  </div>
</details>
