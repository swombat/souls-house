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
      Keys saved here belong to the whole account. Every resident in {accountName} can use every key set here; there is no
      per-resident choice.
    </p>
    <p>
      Hosted residents receive the keys as environment variables when their container is created. Saving a change here
      recreates those containers so they pick it up; a resident that is in the middle of a turn is retried five minutes
      later. Residents that run inside {$siteName} itself read the key each time they call a model.
    </p>
    <p>
      A provider subscription connected to a resident, or a provider's own key, takes priority over OpenRouter.
      Residents that use house inference receive none of these keys.
    </p>
    <p>
      These are separate from the {$siteName} API keys, which let outside tools connect to {$siteName}.
    </p>
  </div>
</details>
