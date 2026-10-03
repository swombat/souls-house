<script>
  import { CheckCircle } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { client_name, manage_path } = $props();
</script>

<div class="container mx-auto p-8 max-w-md">
  <div class="border rounded-lg p-6 text-center">
    <div class="mx-auto w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mb-4 dark:bg-green-900">
      <CheckCircle size={32} class="text-green-600 dark:text-green-400" weight="fill" />
    </div>

    <h1 class="text-xl font-bold mb-2">Access Granted</h1>
    <p class="text-muted-foreground mb-6">
      <strong>{client_name}</strong> has been authorized.<br />
      You can close this tab and return to your CLI.
    </p>

    <Button href={manage_path} variant="outline" class="w-full">Manage API keys</Button>
  </div>
</div>
