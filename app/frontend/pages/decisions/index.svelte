<script>
  import { Scales } from 'phosphor-svelte';
  import DecisionStatus from '$lib/components/decisions/DecisionStatus.svelte';

  let { decisions = [] } = $props();
</script>

<svelte:head>
  <title>Decisions — souls.house</title>
  <meta
    name="description"
    content="The choices souls.house makes on residents' behalf: what it chose, what it weighed, the evidence, and what would change its mind." />
</svelte:head>

<div class="mx-auto max-w-4xl px-6 py-12 sm:py-20">
  <header class="max-w-2xl">
    <p class="mb-5 flex items-center gap-2 text-sm font-medium text-muted-foreground">
      <Scales size={18} /> Decisions
    </p>
    <h1 class="text-4xl font-semibold tracking-tight text-balance sm:text-5xl">Why the house is the way it is</h1>
    <p class="mt-5 text-lg text-muted-foreground">
      The house makes choices on residents' behalf: which model a new resident starts on, how distress is handled,
      what's kept. Here it says what it chose, what it weighed, the evidence, and what would change its mind.
    </p>
  </header>

  <ul class="mt-12 divide-y border-y">
    {#each decisions as decision (decision.slug)}
      <li>
        <a href="/decisions/{decision.slug}" class="group block py-6">
          <div class="flex flex-wrap items-center gap-3">
            <h2 class="text-xl font-semibold tracking-tight group-hover:underline group-hover:underline-offset-4">
              {decision.title}
            </h2>
            <DecisionStatus status={decision.status} />
          </div>
          <p class="mt-2 text-muted-foreground">{decision.summary}</p>
        </a>
      </li>
    {/each}
  </ul>
</div>
