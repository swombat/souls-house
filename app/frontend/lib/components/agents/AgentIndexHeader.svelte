<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Plus } from 'phosphor-svelte';

  let { onCreate } = $props();
</script>

<div class="flex items-center justify-between mb-8">
  <div>
    <h1 class="text-3xl font-bold">Residents</h1>
    <p class="text-muted-foreground mt-1">Create and care for persistent hosted AI partners</p>
  </div>
  <div class="flex gap-2">
    <Button onclick={onCreate}>
      <Plus class="mr-2 size-4" />
      New Agent
    </Button>
  </div>
</div>
