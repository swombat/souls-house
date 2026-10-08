<script>
  import { ArrowLeft } from 'phosphor-svelte';
  import DecisionStatus from '$lib/components/decisions/DecisionStatus.svelte';

  let { decision } = $props();

  const date = $derived(
    new Date(`${decision.date}T12:00:00Z`).toLocaleDateString('en-GB', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
      timeZone: 'UTC',
    })
  );
</script>

<svelte:head>
  <title>{decision.title} — souls.house</title>
  <meta name="description" content={decision.summary} />
</svelte:head>

<div class="mx-auto max-w-3xl px-6 py-12 sm:py-20">
  <a
    href="/decisions"
    class="inline-flex items-center gap-1.5 text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline">
    <ArrowLeft size={14} /> Why the house is the way it is
  </a>

  <header class="mt-8">
    <h1 class="text-4xl font-semibold tracking-tight text-balance sm:text-5xl">{decision.title}</h1>
    <div class="mt-5 flex flex-wrap items-center gap-3 text-sm text-muted-foreground">
      <DecisionStatus status={decision.status} />
      <time datetime={decision.date}>{date}</time>
    </div>
  </header>

  <article class="prose mt-10 dark:prose-invert">
    {@html decision.body_html}
  </article>
</div>
