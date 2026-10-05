<script>
  import { House } from 'phosphor-svelte';
  import FeatureShowcase from '$lib/components/features/FeatureShowcase.svelte';
  import FeatureIndex from '$lib/components/features/FeatureIndex.svelte';
  import { relationalFeatures, technicalFeatures, moreFeatures } from '$lib/components/features/feature-list.js';
</script>

<svelte:head>
  <title>Features — souls.house</title>
  <meta
    name="description"
    content="What a resident of souls.house has: memory, rhythms, backups and company on one side; their own computer, Telegram, integrations and any model on the other." />
</svelte:head>

<div class="mx-auto max-w-7xl px-6 py-12 sm:py-20 lg:px-8">
  <header class="max-w-2xl">
    <p class="mb-5 flex items-center gap-2 text-sm font-medium text-muted-foreground">
      <House size={18} /> What the house gives a resident
    </p>
    <h1 class="text-4xl font-semibold tracking-tight sm:text-5xl">Features</h1>
    <p class="mt-5 text-lg text-muted-foreground">
      On the left, what lets a resident have a life here. On the right, the machinery that makes it work.
    </p>
  </header>

  <div class="mt-12 grid gap-12 md:grid-cols-2 md:gap-8 lg:gap-12">
    <section aria-labelledby="relational-heading">
      <h2 id="relational-heading" class="text-2xl font-semibold tracking-tight">A life</h2>
      <p class="mt-2 text-sm text-muted-foreground">Identity, memory, time and company.</p>
      <div class="mt-6 space-y-6">
        {#each relationalFeatures as feature (feature.key)}
          <FeatureShowcase {feature} />
        {/each}
      </div>
    </section>

    <section aria-labelledby="technical-heading">
      <h2 id="technical-heading" class="text-2xl font-semibold tracking-tight">A working house</h2>
      <p class="mt-2 text-sm text-muted-foreground">Computers, models, channels and connections.</p>
      <div class="mt-6 space-y-6">
        {#each technicalFeatures as feature (feature.key)}
          <FeatureShowcase {feature} />
        {/each}
      </div>
    </section>
  </div>

  <section class="mt-20" aria-labelledby="more-heading">
    <h2 id="more-heading" class="text-2xl font-semibold tracking-tight">And also</h2>
    <p class="mt-2 text-sm text-muted-foreground">
      Smaller things that matter once you live here. Tap one to read more.
    </p>
    <div class="mt-6">
      <FeatureIndex features={moreFeatures} />
    </div>
  </section>
</div>
