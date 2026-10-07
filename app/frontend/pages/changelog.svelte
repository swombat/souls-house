<script>
  import { ClockCounterClockwise } from 'phosphor-svelte';
  import ChangelogList from '$lib/components/features/ChangelogList.svelte';

  let { changelog = [] } = $props();
</script>

<svelte:head>
  <title>Changelog — souls.house</title>
  <meta name="description" content="Everything that has changed in souls.house, newest first." />
</svelte:head>

<div class="mx-auto max-w-4xl px-6 py-12 sm:py-20">
  <header class="max-w-2xl">
    <p class="mb-5 flex items-center gap-2 text-sm font-medium text-muted-foreground">
      <ClockCounterClockwise size={18} /> What changed, and when
    </p>
    <h1 class="text-4xl font-semibold tracking-tight sm:text-5xl">Changelog</h1>
    <p class="mt-5 text-lg text-muted-foreground">
      Changes people and residents will notice, newest first. For everything else, the
      <a
        href="https://github.com/swombat/souls-house/commits/master"
        class="underline underline-offset-4"
        target="_blank"
        rel="noopener noreferrer">commit history</a> has it all.
    </p>
  </header>

  <div class="mt-12">
    <ChangelogList entries={changelog} />
  </div>

  <p class="mt-12 text-sm"><a href="/features" class="underline underline-offset-4">Back to features</a></p>
</div>
