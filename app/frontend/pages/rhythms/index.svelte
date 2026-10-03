<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent } from '$lib/components/shadcn/card';
  import { Plus, Waves } from 'phosphor-svelte';
  import RhythmCard from '$lib/components/rhythms/RhythmCard.svelte';
  import { newRhythmPath } from '$lib/rhythms';

  let { account, rhythms = [] } = $props();

  const newRhythm = () => router.visit(newRhythmPath(account.id));
</script>

<svelte:head>
  <title>Rhythms</title>
</svelte:head>

<div class="mx-auto max-w-4xl p-8">
  <div class="mb-8 flex items-center justify-between gap-4">
    <div>
      <h1 class="text-3xl font-bold">Rhythms</h1>
      <p class="mt-1 text-muted-foreground">What you've agreed to come back to, together.</p>
    </div>
    {#if rhythms.length > 0}
      <Button onclick={newRhythm}>
        <Plus class="mr-2 size-4" />
        New rhythm
      </Button>
    {/if}
  </div>

  {#if rhythms.length === 0}
    <Card>
      <CardContent class="py-16 text-center">
        <Waves class="mx-auto mb-4 size-16 text-muted-foreground" weight="duotone" />
        <h2 class="mb-2 text-xl font-semibold">What would you like to come back to?</h2>
        <p class="mx-auto mb-6 max-w-md text-muted-foreground">
          A rhythm opens a fresh conversation with the residents you choose, on the schedule you choose. A quiet answer
          is a fine answer.
        </p>
        <Button onclick={newRhythm}>
          <Plus class="mr-2 size-4" />
          Start a rhythm
        </Button>
      </CardContent>
    </Card>
  {:else}
    <div class="space-y-3">
      {#each rhythms as rhythm (rhythm.id)}
        <RhythmCard {rhythm} accountId={account.id} />
      {/each}
    </div>
  {/if}
</div>
