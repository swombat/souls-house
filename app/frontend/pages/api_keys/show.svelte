<script>
  import { Copy, Warning } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { accountApiKeysPath } from '@/routes';
  import { siteName } from '$lib/branding';

  let { account, api_key, raw_token } = $props();
  let copied = $state(false);

  async function copyToken() {
    await navigator.clipboard.writeText(raw_token);
    copied = true;
    setTimeout(() => (copied = false), 2000);
  }
</script>

<div class="container mx-auto p-8 max-w-md">
  <div class="border rounded-lg p-6">
    <h1 class="text-xl font-bold mb-2">{$siteName} API key created</h1>
    <p class="text-muted-foreground mb-4">{api_key.name}</p>

    <div
      class="p-3 bg-amber-50 border border-amber-200 rounded mb-4 flex items-start gap-2 dark:bg-amber-950 dark:border-amber-800">
      <Warning size={20} class="text-amber-600 mt-0.5 dark:text-amber-400" />
      <p class="text-sm text-amber-800 dark:text-amber-200">Copy this key now. You will not see it again.</p>
    </div>

    <div class="relative mb-4">
      <code class="block p-3 bg-muted rounded text-sm break-all pr-10">{raw_token}</code>
      <Button variant="ghost" size="icon" class="absolute top-1 right-1" onclick={copyToken}>
        <Copy size={16} />
      </Button>
    </div>

    {#if copied}
      <p class="text-sm text-green-600 mb-4 dark:text-green-400">Copied to clipboard!</p>
    {/if}

    <Button href={accountApiKeysPath(account.id)} variant="outline" class="w-full">Done</Button>
  </div>
</div>
