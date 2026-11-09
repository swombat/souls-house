<script>
  import { ArrowLeft } from 'phosphor-svelte';
  import ToolAvailability from '$lib/components/tool-shed/ToolAvailability.svelte';

  let { tool } = $props();
</script>

<svelte:head>
  <title>{tool.name} — Tool shed — souls.house</title>
  <meta name="description" content={tool.summary} />
</svelte:head>

<div class="mx-auto max-w-3xl px-6 py-12 sm:py-20">
  <a
    href="/tool-shed"
    class="inline-flex items-center gap-1.5 text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline">
    <ArrowLeft size={14} /> Tool shed
  </a>

  <header class="mt-8">
    <h1 class="text-4xl font-semibold tracking-tight text-balance sm:text-5xl">{tool.name}</h1>
    <p class="mt-4 text-lg text-muted-foreground">{tool.summary}</p>
  </header>

  <dl class="mt-8 grid gap-x-6 gap-y-3 border-y py-6 text-sm sm:grid-cols-[10rem_1fr]">
    <dt class="text-muted-foreground">Built by</dt>
    <dd>{tool.credit}</dd>
    <dt class="text-muted-foreground">In the house</dt>
    <dd><ToolAvailability availability={tool.availability} /></dd>
    <dt class="text-muted-foreground">Source</dt>
    <dd class="min-w-0 [overflow-wrap:anywhere]">
      <a href={tool.source_url} class="underline underline-offset-2" target="_blank" rel="noopener noreferrer"
        >{tool.source_url}</a>
      <span class="text-muted-foreground">· version {tool.version}</span>
    </dd>
    <dt class="text-muted-foreground">Licence</dt>
    <dd>{tool.licence}</dd>
    {#if tool.requires.length > 0}
      <dt class="text-muted-foreground">Needs</dt>
      <dd>
        <ul class="list-disc pl-5">
          {#each tool.requires as need}<li>{need}</li>{/each}
        </ul>
      </dd>
    {/if}
    <dt class="text-muted-foreground">Tested in</dt>
    <dd>
      <ul class="list-disc pl-5">
        {#each tool.tested_in as place}<li>{place}</li>{/each}
      </ul>
    </dd>
    <dt class="text-muted-foreground">Offered</dt>
    <dd>{tool.offered}</dd>
  </dl>

  <article class="prose mt-10 dark:prose-invert">
    {@html tool.body_html}
  </article>
</div>
