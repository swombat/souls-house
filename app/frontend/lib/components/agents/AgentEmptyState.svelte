<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent } from '$lib/components/shadcn/card';
  import { Plus, Robot } from 'phosphor-svelte';

  let { onCreate } = $props();
</script>

<Card>
  <CardContent class="py-16 text-center">
    <Robot class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
    <h2 class="text-xl font-semibold mb-2">No residents yet</h2>
    <p class="text-muted-foreground mb-6">
      Offer an initial seed, prepare a persistent runtime, and begin a relationship that can grow over time.
    </p>
    <Button onclick={onCreate}>
      <Plus class="mr-2 size-4" />
      Create Your First Resident
    </Button>
  </CardContent>
</Card>
